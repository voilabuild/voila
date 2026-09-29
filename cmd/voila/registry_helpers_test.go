package main

import (
	"testing"

	"voila/internal/cli"
)

func TestResolveRegistryFromLoginFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("VOILA_REGISTRY", "")
	t.Setenv("VOILA_REGISTRY_TOKEN", "")

	const url = "https://login.example/registry"
	if err := saveLoginCredsForTest(url, "dreg_file"); err != nil {
		t.Fatal(err)
	}
	if got := resolveRegistry(""); got != url {
		t.Fatalf("resolveRegistry = %q, want %q", got, url)
	}
	if got := resolveRegistryToken(); got != "dreg_file" {
		t.Fatalf("resolveRegistryToken = %q, want dreg_file", got)
	}
}

func TestResolveRegistryEnvOverridesLoginFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := saveLoginCredsForTest("https://file.example/registry", "dreg_file"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("VOILA_REGISTRY", "https://env.example/registry")
	t.Setenv("VOILA_REGISTRY_TOKEN", "dreg_env")

	if got := resolveRegistry(""); got != "https://env.example/registry" {
		t.Fatalf("resolveRegistry = %q, want env URL", got)
	}
	if got := resolveRegistryToken(); got != "dreg_env" {
		t.Fatalf("resolveRegistryToken = %q, want dreg_env", got)
	}
}

func TestResolveRegistryFlagOverridesAll(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := saveLoginCredsForTest("https://file.example/registry", "dreg_file"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("VOILA_REGISTRY", "https://env.example/registry")
	t.Setenv("VOILA_REGISTRY_TOKEN", "dreg_env")

	if got := resolveRegistry("https://flag.example/registry"); got != "https://flag.example/registry" {
		t.Fatalf("resolveRegistry = %q, want flag URL", got)
	}
}

func saveLoginCredsForTest(url, tok string) error {
	return cli.SaveLoginCreds(url, tok)
}
