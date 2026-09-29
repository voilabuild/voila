package registry

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"github.com/pb33f/libopenapi"
	libopenapivalidator "github.com/pb33f/libopenapi-validator"
	libopenapierrors "github.com/pb33f/libopenapi-validator/errors"
	"lukechampine.com/blake3"
)

// TestOpenAPIContract validates that the running registry server's responses
// conform to the embedded OpenAPI 3.1 spec. It loads the same openapi.yaml the
// server serves (via go:embed), builds a validator from it, and checks every
// route's happy path and key error paths against the spec.
//
// This is the guard against spec/implementation voila: if the server's
// response shape, status code, or content type diverges from the spec, this
// test fails.
func TestOpenAPIContract(t *testing.T) {
	// Build the validator from the embedded spec — the same bytes the server
	// serves at GET /openapi.yaml.
	doc, err := libopenapi.NewDocument(openapiYAML)
	if err != nil {
		t.Fatalf("libopenapi.NewDocument: %v", err)
	}
	v, vErrs := libopenapivalidator.NewValidator(doc)
	if len(vErrs) > 0 {
		t.Fatalf("validator.NewValidator: %v", vErrs)
	}

	// Validate the document itself against the OpenAPI 3.1 schema.
	ok, docErrs := v.ValidateDocument()
	if !ok {
		t.Fatalf("OpenAPI document is invalid: %v", docErrs)
	}

	ts, _, c, _ := newTestServer(t)
	ctx := context.Background()

	// Helper: validate a request/response pair against the spec.
	// skipReqValidation is true for intentionally-invalid requests (e.g.
	// malformed JSON bodies, unknown paths) where we only check the response.
	validate := func(t *testing.T, method, path string, reqBody []byte, reqHeaders map[string]string, skipReqValidation bool) (*http.Response, []byte) {
		t.Helper()
		var bodyReader io.Reader
		if reqBody != nil {
			bodyReader = bytes.NewReader(reqBody)
		}
		valReq, err := http.NewRequest(method, ts.URL+path, bodyReader)
		if err != nil {
			t.Fatalf("NewRequest: %v", err)
		}
		for k, v := range reqHeaders {
			valReq.Header.Set(k, v)
		}
		if reqBody != nil {
			valReq.ContentLength = int64(len(reqBody))
		}

		// Validate the request against the spec (unless skipped for
		// intentionally-invalid requests).
		if !skipReqValidation {
			ok, reqErrs := v.ValidateHttpRequestSync(valReq)
			if !ok {
				t.Errorf("request %s %s failed spec validation: %v", method, path, formatErrs(reqErrs))
			}
		}

		// Send the actual request.
		sendReq, err := http.NewRequest(method, ts.URL+path, bytes.NewReader(reqBody))
		if err != nil {
			t.Fatalf("NewRequest (send): %v", err)
		}
		for k, v := range reqHeaders {
			sendReq.Header.Set(k, v)
		}
		if reqBody != nil {
			sendReq.ContentLength = int64(len(reqBody))
		}
		resp, err := http.DefaultClient.Do(sendReq)
		if err != nil {
			t.Fatalf("Do: %v", err)
		}
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		// Validate the response (only if the path is in the spec).
		valReq2, _ := http.NewRequest(method, ts.URL+path, nil)
		for k, v := range reqHeaders {
			valReq2.Header.Set(k, v)
		}
		valResp := &http.Response{
			StatusCode:    resp.StatusCode,
			Header:        resp.Header.Clone(),
			Body:          io.NopCloser(bytes.NewReader(respBody)),
			ContentLength: int64(len(respBody)),
		}
		ok, respErrs := v.ValidateHttpResponse(valReq2, valResp)
		if !ok {
			t.Errorf("response %s %s (status %d) failed spec validation: %v",
				method, path, resp.StatusCode, formatErrs(respErrs))
		}
		return resp, respBody
	}

	// --- Health ---
	t.Run("GET /healthz", func(t *testing.T) {
		validate(t, "GET", "/healthz", nil, nil, false)
	})

	// --- OpenAPI self-serve ---
	t.Run("GET /openapi.yaml", func(t *testing.T) {
		validate(t, "GET", "/openapi.yaml", nil, nil, false)
	})

	// --- Chunk round trip ---
	t.Run("chunk PUT/GET/HEAD", func(t *testing.T) {
		payload := []byte("contract test chunk payload")
		id := chunkstore.ChunkID(blake3.Sum256(payload))
		chunkPath := "/v1/chunks/" + id.String()

		// PUT (201)
		validate(t, "PUT", chunkPath, payload, map[string]string{
			"Content-Type": "application/octet-stream",
		}, false)
		// GET (200)
		validate(t, "GET", chunkPath, nil, nil, false)
		// HEAD (200)
		validate(t, "HEAD", chunkPath, nil, nil, false)
	})

	// --- Chunk not found ---
	t.Run("GET missing chunk 404", func(t *testing.T) {
		var id chunkstore.ChunkID
		id[0] = 0x42
		validate(t, "GET", "/v1/chunks/"+id.String(), nil, nil, false)
	})

	// --- Chunk hash mismatch ---
	t.Run("PUT chunk hash mismatch 400", func(t *testing.T) {
		var id chunkstore.ChunkID
		id[0] = 0x99
		validate(t, "PUT", "/v1/chunks/"+id.String(), []byte("wrong bytes"), map[string]string{
			"Content-Type": "application/octet-stream",
		}, false)
	})

	// --- Missing endpoint ---
	t.Run("POST /v1/chunks/missing", func(t *testing.T) {
		payload := []byte("missing-test-chunk")
		id := chunkstore.ChunkID(blake3.Sum256(payload))
		// PUT the chunk so the server has it.
		c.PutChunk(ctx, id, payload)

		absent := chunkstore.ChunkID(blake3.Sum256([]byte("absent-chunk")))
		reqBody, _ := json.Marshal(struct {
			IDs []string `json:"ids"`
		}{IDs: []string{id.String(), absent.String()}})

		validate(t, "POST", "/v1/chunks/missing", reqBody, map[string]string{
			"Content-Type": "application/json",
		}, false)
	})

	// --- Missing endpoint empty request ---
	t.Run("POST /v1/chunks/missing empty", func(t *testing.T) {
		validate(t, "POST", "/v1/chunks/missing", nil, nil, false)
	})

	// --- Image round trip ---
	t.Run("image PUT/GET", func(t *testing.T) {
		im := &voilapb.ImageManifest{
			ImageRef:                "contract:v1",
			ImageDigest:             bytes.Repeat([]byte{0xde}, 32),
			ConfigChunk:             bytes.Repeat([]byte{0xad}, 32),
			MergedRootManifestChunk: bytes.Repeat([]byte{0xbe}, 32),
			TotalSize:               999,
			ChunkCount:              3,
		}
		jsonBody, _ := json.Marshal(manifestToJSON(im))
		ref := "contract%3Av1"
		// PUT
		validate(t, "PUT", "/v1/images/"+ref, jsonBody, map[string]string{
			"Content-Type": "application/json",
		}, false)
		// GET
		validate(t, "GET", "/v1/images/"+ref, nil, nil, false)
	})

	// --- Image not found ---
	t.Run("GET missing image 404", func(t *testing.T) {
		validate(t, "GET", "/v1/images/nonexistent%3Av1", nil, nil, false)
	})

	// --- Image invalid JSON (intentionally malformed request body) ---
	t.Run("PUT image invalid JSON 400", func(t *testing.T) {
		validate(t, "PUT", "/v1/images/bad%3Av1", []byte("{not json"), map[string]string{
			"Content-Type": "application/json",
		}, true)
	})

	// --- Unknown path 404 (not in spec; just check the status code) ---
	t.Run("unknown path 404", func(t *testing.T) {
		req, _ := http.NewRequest("GET", ts.URL+"/nonexistent", nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("Do: %v", err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, resp.Body)
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("unknown path status = %d, want 404", resp.StatusCode)
		}
	})
}

// formatErrs converts a slice of ValidationError into a readable string.
func formatErrs(errs []*libopenapierrors.ValidationError) string {
	var b strings.Builder
	for _, e := range errs {
		b.WriteString(e.Message)
		if e.Reason != "" {
			b.WriteString(" (")
			b.WriteString(e.Reason)
			b.WriteString(")")
		}
		b.WriteString("; ")
	}
	return b.String()
}
