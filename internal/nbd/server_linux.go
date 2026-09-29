//go:build linux

package nbd

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/pojntfx/go-nbd/pkg/server"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
)

// NBD ioctl constants (from include/uapi/linux/nbd.h).
const (
	nbdSetSock       = 0xab00 // _IO(0xab, 0)
	nbdSetBlksize    = 0xab01 // _IO(0xab, 1)
	nbdDoIt          = 0xab03 // _IO(0xab, 3)
	nbdClearSock     = 0xab04 // _IO(0xab, 4)
	nbdSetSizeBlocks = 0xab07 // _IO(0xab, 7)
	nbdDisconnect    = 0xab08 // _IO(0xab, 8)
	nbdSetFlags      = 0xab0a // _IO(0xab, 10)

	nbdFlagHasFlags = 1 << 0 // NBD_FLAG_HAS_FLAGS
	nbdFlagReadOnly = 1 << 1 // NBD_FLAG_READ_ONLY
)

// Device wraps a running NBD device: the server goroutine, the /dev/nbdX
// file, and the refcount of contexts using it.
type Device struct {
	path    string
	devFile *os.File
	backend *chunkBackend
	done    chan struct{}

	mu      int
	muMutex sync.Mutex
}

// Path returns the /dev/nbdX path.
func (d *Device) Path() string { return d.path }

// Acquire increments the refcount.
func (d *Device) Acquire() bool {
	d.muMutex.Lock()
	defer d.muMutex.Unlock()
	d.mu++
	return d.mu == 1
}

// Release decrements the refcount. Returns true if this was the last user.
func (d *Device) Release() bool {
	d.muMutex.Lock()
	defer d.muMutex.Unlock()
	d.mu--
	return d.mu == 0
}

// Close shuts down the NBD server and disconnects the device.
func (d *Device) Close() error {
	// Disconnect the kernel device (causes NBD_DO_IT to return, which closes
	// the server's connection and lets the goroutine finish).
	ioctl(d.devFile.Fd(), nbdDisconnect, 0)
	ioctl(d.devFile.Fd(), nbdClearSock, 0)
	<-d.done
	_ = d.devFile.Close()
	return nil
}

// Registry manages per-image NBD devices.
type Registry struct {
	mu      sync.Mutex
	devices map[string]*Device
}

func NewRegistry() *Registry {
	return &Registry{devices: make(map[string]*Device)}
}

// Acquire returns a Device for the given build result, creating one if
// none exists for this image key. The caller must call Release when done.
func (r *Registry) Acquire(ctx context.Context, key string, result *erofsadapter.BuildResult, store chunkstore.ChunkStore) (*Device, error) {
	r.mu.Lock()
	if d, ok := r.devices[key]; ok {
		d.Acquire()
		r.mu.Unlock()
		return d, nil
	}
	r.mu.Unlock()

	d, err := createDevice(ctx, result, store)
	if err != nil {
		return nil, err
	}
	d.Acquire()
	r.mu.Lock()
	r.devices[key] = d
	r.mu.Unlock()
	return d, nil
}

// Release decrements the refcount, closing the device when the last user
// releases.
func (r *Registry) Release(key string) {
	r.mu.Lock()
	d, ok := r.devices[key]
	if !ok {
		r.mu.Unlock()
		return
	}
	if d.Release() {
		delete(r.devices, key)
		r.mu.Unlock()
		_ = d.Close()
		return
	}
	r.mu.Unlock()
}

func createDevice(ctx context.Context, result *erofsadapter.BuildResult, store chunkstore.ChunkStore) (*Device, error) {
	devPath, err := findFreeNBD()
	if err != nil {
		return nil, fmt.Errorf("nbd: no free device: %w", err)
	}

	devFile, err := os.OpenFile(devPath, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("nbd: open %s: %w", devPath, err)
	}

	// Use a TCP listener for the NBD server.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: listen: %w", err)
	}

	// Start the NBD server: accept one connection and handle it.
	backend := newChunkBackend(result, store)
	done := make(chan struct{})

	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		_ = listener.Close()
		_ = server.Handle(conn,
			[]*server.Export{{Name: "default", Backend: backend}},
			&server.Options{ReadOnly: true, PreferredBlockSize: 4096})
		_ = conn.Close()
	}()

	waitCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	// Listen() already admits connections; retry only if Accept hasn't
	// been scheduled yet (ECONNREFUSED), instead of sleeping blindly.
	conn, err := dialNBD(waitCtx, listener.Addr().String())
	if err != nil {
		_ = listener.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: dial: %w", err)
	}

	// NBD newstyle negotiation:
	// 1. Read server header: magic(8) + flags(2) + ... = 18 bytes
	// 2. Send client flags (4 bytes)
	// 3. Send NBD_OPT_GO option
	// 4. Read server reply
	// 5. Call NBD_SET_SOCK, NBD_SET_BLKSIZE, NBD_SET_SIZE_BLOCKS, NBD_SET_FLAGS
	// 6. Call NBD_DO_IT

	// Step 1: Read the server negotiation header.
	header := make([]byte, 18)
	if _, err := io.ReadFull(conn, header); err != nil {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: read header: %w", err)
	}
	if string(header[:8]) != "NBDMAGIC" {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: bad magic: %q", header[:8])
	}

	// Step 2: Send client flags (NBD_FLAG_C_FIXED_NEWSTYLE | NBD_FLAG_C_NO_ZEROES).
	clientFlags := make([]byte, 4)
	binary.BigEndian.PutUint32(clientFlags, 3) // FIXED_NEWSTYLE | NO_ZEROES
	if _, err := conn.Write(clientFlags); err != nil {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: send client flags: %w", err)
	}

	// Step 3: Send NBD_OPT_GO with export name "default".
	exportName := "default"
	optLen := 4 + len(exportName) + 2 // namelen(4) + name + info_count(2)
	optHeader := make([]byte, 16)
	binary.BigEndian.PutUint64(optHeader[0:8], 0x49484156454F5054) // "IHAVEOPT"
	binary.BigEndian.PutUint32(optHeader[8:12], 7)                 // NBD_OPT_GO
	binary.BigEndian.PutUint32(optHeader[12:16], uint32(optLen))
	if _, err := conn.Write(optHeader); err != nil {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: send option header: %w", err)
	}
	// Option data: namelen(4) + name + info_count(2, =0)
	optData := make([]byte, optLen)
	binary.BigEndian.PutUint32(optData[0:4], uint32(len(exportName)))
	copy(optData[4:], exportName)
	binary.BigEndian.PutUint16(optData[4+len(exportName):], 0) // 0 info requests
	if _, err := conn.Write(optData); err != nil {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: send option data: %w", err)
	}

	// Step 4: Read server replies until NBD_REP_ACK.
	var exportSize uint64
	for {
		// Reply: magic(8) + id(4) + type(4) + length(4)
		reply := make([]byte, 20)
		if _, err := io.ReadFull(conn, reply); err != nil {
			_ = listener.Close()
			_ = conn.Close()
			_ = devFile.Close()
			return nil, fmt.Errorf("nbd: read reply: %w", err)
		}
		repType := binary.BigEndian.Uint32(reply[12:16])
		repLen := binary.BigEndian.Uint32(reply[16:20])

		if repType == 1 { // NBD_REP_ACK
			break
		}
		if repType == 2 { // NBD_REP_INFO
			info := make([]byte, repLen)
			if _, err := io.ReadFull(conn, info); err != nil {
				_ = listener.Close()
				_ = conn.Close()
				_ = devFile.Close()
				return nil, fmt.Errorf("nbd: read info: %w", err)
			}
			if len(info) >= 12 && info[0] == 0 { // NBD_INFO_EXPORT
				exportSize = binary.BigEndian.Uint64(info[2:10])
			}
			continue
		}
		if repType >= 0x80000000 { // Error
			errData := make([]byte, repLen)
			_, _ = io.ReadFull(conn, errData)
			_ = listener.Close()
			_ = conn.Close()
			_ = devFile.Close()
			return nil, fmt.Errorf("nbd: server error: type=0x%x data=%q", repType, errData)
		}
		// Skip unknown reply types.
		if repLen > 0 {
			skip := make([]byte, repLen)
			_, _ = io.ReadFull(conn, skip)
		}
	}

	if exportSize == 0 {
		exportSize = uint64(result.DeviceSize)
	}

	// Step 5: Extract the socket fd and call NBD_SET_SOCK.
	tcpConn := conn.(*net.TCPConn)
	tcpFile, err := tcpConn.File()
	if err != nil {
		_ = listener.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: tcp File: %w", err)
	}
	sockFd := tcpFile.Fd()

	if err := ioctl(devFile.Fd(), nbdSetSock, sockFd); err != nil {
		_ = listener.Close()
		_ = tcpFile.Close()
		_ = conn.Close()
		_ = devFile.Close()
		return nil, fmt.Errorf("nbd: NBD_SET_SOCK: %w", err)
	}
	_ = tcpFile.Close()
	_ = conn.Close()

	// Step 6: Set block size, device size, and flags.
	if err := ioctl(devFile.Fd(), nbdSetBlksize, 4096); err != nil {
		return nil, fmt.Errorf("nbd: NBD_SET_BLKSIZE: %w", err)
	}
	numBlocks := exportSize / 4096
	if exportSize%4096 != 0 {
		numBlocks++
	}
	if err := ioctl(devFile.Fd(), nbdSetSizeBlocks, uintptr(numBlocks)); err != nil {
		return nil, fmt.Errorf("nbd: NBD_SET_SIZE_BLOCKS: %w", err)
	}
	if err := ioctl(devFile.Fd(), nbdSetFlags, uintptr(nbdFlagHasFlags|nbdFlagReadOnly)); err != nil {
		return nil, fmt.Errorf("nbd: NBD_SET_FLAGS: %w", err)
	}

	// Step 7: Start NBD_DO_IT in a goroutine (blocks until disconnect).
	go func() {
		_ = ioctl(devFile.Fd(), nbdDoIt, 0)
	}()

	// /sys/block/nbdX/pid appears once the kernel is servicing the device.
	if err := waitNBDConnected(waitCtx, devPath); err != nil {
		ioctl(devFile.Fd(), nbdDisconnect, 0)
		ioctl(devFile.Fd(), nbdClearSock, 0)
		_ = listener.Close()
		_ = devFile.Close()
		return nil, err
	}

	return &Device{
		path:    devPath,
		devFile: devFile,
		backend: backend,
		done:    done,
	}, nil
}

func dialNBD(ctx context.Context, addr string) (net.Conn, error) {
	d := net.Dialer{Timeout: 20 * time.Millisecond}
	var last error
	for {
		conn, err := d.DialContext(ctx, "tcp", addr)
		if err == nil {
			return conn, nil
		}
		last = err
		select {
		case <-ctx.Done():
			if last != nil {
				return nil, fmt.Errorf("%w (%v)", ctx.Err(), last)
			}
			return nil, ctx.Err()
		case <-time.After(time.Millisecond):
		}
	}
}

// waitNBDConnected returns when the kernel has entered NBD_DO_IT for
// devPath. That is when /sys/block/nbdX/pid is populated.
func waitNBDConnected(ctx context.Context, devPath string) error {
	name := devPath
	if i := strings.LastIndex(devPath, "/"); i >= 0 {
		name = devPath[i+1:]
	}
	pidPath := "/sys/block/" + name + "/pid"
	for {
		if b, err := os.ReadFile(pidPath); err == nil && len(strings.TrimSpace(string(b))) > 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("nbd: wait for %s: %w", devPath, ctx.Err())
		case <-time.After(time.Millisecond):
		}
	}
}

// HasFreeDevice reports whether a /dev/nbd* node can be opened for
// NBD_SET_SOCK. Used by the worker to decide if the EROFS backend is usable.
func HasFreeDevice() bool {
	_, err := findFreeNBD()
	return err == nil
}

// findFreeNBD scans /dev/nbd0..nbd15 for a device that can be opened.
func findFreeNBD() (string, error) {
	for i := 0; i < 16; i++ {
		p := fmt.Sprintf("/dev/nbd%d", i)
		f, err := os.OpenFile(p, os.O_RDWR, 0)
		if err != nil {
			continue
		}
		_ = f.Close()
		return p, nil
	}
	return "", fmt.Errorf("all /dev/nbd* devices are in use")
}

// ioctl makes a Linux ioctl syscall on fd.
func ioctl(fd uintptr, req uint, arg uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(req), arg)
	if errno != 0 {
		return errno
	}
	return nil
}
