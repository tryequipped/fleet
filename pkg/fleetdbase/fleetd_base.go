// package fleetdbase contains functions to interact with the fleetd base
// package download server. By default this is download.fleetdm.com, but
// Equipped overrides it via FLEET_FLEETD_BASE_URL to serve rebranded packages.
package fleetdbase

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"

	"github.com/fleetdm/fleet/v4/server/dev_mode"
)

type Metadata struct {
	MSIURL           string `json:"fleetd_base_msi_url"`
	MSISha256        string `json:"fleetd_base_msi_sha256"`
	PKGURL           string `json:"fleetd_base_pkg_url"`
	PKGSha256        string `json:"fleetd_base_pkg_sha256"`
	ManifestPlistURL string `json:"fleetd_base_manifest_plist_url"`
	Version          string `json:"version"`
}

func getBaseURL() string {
	// FLEET_FLEETD_BASE_URL allows overriding the download server URL
	// in production (not gated behind dev_mode). Used by Equipped to
	// serve rebranded agent packages from its own infrastructure.
	if baseURL := os.Getenv("FLEET_FLEETD_BASE_URL"); baseURL != "" {
		return baseURL
	}
	devURL := dev_mode.Env("FLEET_DEV_DOWNLOAD_FLEETDM_URL")
	if devURL != "" {
		return devURL
	}
	return "https://download.fleetdm.com"
}

func GetMetadata() (*Metadata, error) {
	baseURL := getBaseURL()
	rawURL := fmt.Sprintf("%s/stable/meta.json", baseURL)

	parsedURL, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %w", err)
	}

	resp, err := http.Get(parsedURL.String())
	if err != nil {
		return nil, fmt.Errorf("failed to fetch metadata: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var meta Metadata
	if err := json.NewDecoder(resp.Body).Decode(&meta); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &meta, nil
}

func GetPKGManifestURL() string {
	baseURL := getBaseURL()
	return fmt.Sprintf("%s/stable/fleetd-base-manifest.plist", baseURL)
}
