// Cedana Credentials Refresher
//
// A simple sidecar that fetches temporary AWS credentials from the Cedana Propagator
// and writes them to a file for Vector to use.
//
// Environment Variables:
//   CEDANA_URL         - Propagator URL (e.g., "https://api.cedana.ai")
//   CEDANA_AUTH_TOKEN  - Bearer token for authentication
//   CLUSTER_ID         - UUID of the cluster requesting credentials
//   REFRESH_INTERVAL   - How often to refresh credentials (default: "45m")
//   CREDENTIALS_FILE   - Path to write credentials (default: "/credentials/aws-credentials")
//   HEALTH_PORT        - Port for health check endpoint (default: "8080")

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

type CredentialRequest struct {
	ClusterID string `json:"cluster_id"`
}

type CredentialResponse struct {
	AccessKeyID     string `json:"access_key_id"`
	SecretAccessKey string `json:"secret_access_key"`
	SessionToken    string `json:"session_token"`
	Expiration      string `json:"expiration"`
	Bucket          string `json:"bucket"`
	Prefix          string `json:"prefix"`
	Region          string `json:"region"`
}

var (
	lastRefreshTime time.Time
	lastError       error
	healthy         bool
)

func main() {
	// Parse configuration from environment
	cedanaURL := mustEnv("CEDANA_URL")
	authToken := mustEnv("CEDANA_AUTH_TOKEN")
	clusterID := mustEnv("CLUSTER_ID")
	refreshInterval := envOrDefault("REFRESH_INTERVAL", "45m")
	credentialsFile := envOrDefault("CREDENTIALS_FILE", "/credentials/aws-credentials")
	healthPort := envOrDefault("HEALTH_PORT", "8080")

	interval, err := time.ParseDuration(refreshInterval)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Invalid REFRESH_INTERVAL: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Starting credentials refresher\n")
	fmt.Printf("  Cedana URL: %s\n", cedanaURL)
	fmt.Printf("  Cluster ID: %s\n", clusterID)
	fmt.Printf("  Refresh Interval: %s\n", interval)
	fmt.Printf("  Credentials File: %s\n", credentialsFile)

	// Start health check server
	go startHealthServer(healthPort)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Println("Received shutdown signal")
		cancel()
	}()

	// Create HTTP client
	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	// Initial fetch
	if err := refreshCredentials(ctx, client, cedanaURL, authToken, clusterID, credentialsFile); err != nil {
		fmt.Fprintf(os.Stderr, "Initial credential fetch failed: %v\n", err)
		// Don't exit - keep trying
	}

	// Refresh loop
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("Shutting down")
			return
		case <-ticker.C:
			if err := refreshCredentials(ctx, client, cedanaURL, authToken, clusterID, credentialsFile); err != nil {
				fmt.Fprintf(os.Stderr, "Credential refresh failed: %v\n", err)
				// Continue - don't exit on refresh failure
			}
		}
	}
}

func refreshCredentials(ctx context.Context, client *http.Client, cedanaURL, authToken, clusterID, credentialsFile string) error {
	fmt.Printf("[%s] Fetching credentials from propagator...\n", time.Now().Format(time.RFC3339))

	// Build request
	reqBody := CredentialRequest{ClusterID: clusterID}
	reqJSON, err := json.Marshal(reqBody)
	if err != nil {
		lastError = err
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	url := fmt.Sprintf("%s/v2/monitoring/credentials", cedanaURL)
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(reqJSON))
	if err != nil {
		lastError = err
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", authToken))

	// Send request
	resp, err := client.Do(req)
	if err != nil {
		lastError = err
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		lastError = err
		return fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		lastError = fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
		return lastError
	}

	// Parse response
	var creds CredentialResponse
	if err := json.Unmarshal(body, &creds); err != nil {
		lastError = err
		return fmt.Errorf("failed to parse response: %w", err)
	}

	// Write credentials file in AWS credentials format
	credContent := fmt.Sprintf(`[default]
aws_access_key_id = %s
aws_secret_access_key = %s
aws_session_token = %s
`, creds.AccessKeyID, creds.SecretAccessKey, creds.SessionToken)

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(credentialsFile), 0755); err != nil {
		lastError = err
		return fmt.Errorf("failed to create credentials directory: %w", err)
	}

	// Write to temp file first, then rename (atomic)
	tmpFile := credentialsFile + ".tmp"
	if err := os.WriteFile(tmpFile, []byte(credContent), 0600); err != nil {
		lastError = err
		return fmt.Errorf("failed to write credentials: %w", err)
	}

	if err := os.Rename(tmpFile, credentialsFile); err != nil {
		lastError = err
		return fmt.Errorf("failed to move credentials file: %w", err)
	}

	lastRefreshTime = time.Now()
	lastError = nil
	healthy = true

	fmt.Printf("[%s] Credentials written successfully (expires: %s, bucket: %s, prefix: %s)\n",
		time.Now().Format(time.RFC3339), creds.Expiration, creds.Bucket, creds.Prefix)

	return nil
}

func startHealthServer(port string) {
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if healthy {
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, "OK (last refresh: %s)\n", lastRefreshTime.Format(time.RFC3339))
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			if lastError != nil {
				fmt.Fprintf(w, "UNHEALTHY: %v\n", lastError)
			} else {
				fmt.Fprintf(w, "UNHEALTHY: no successful refresh yet\n")
			}
		}
	})

	http.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		if healthy {
			w.WriteHeader(http.StatusOK)
			fmt.Fprintln(w, "READY")
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprintln(w, "NOT READY")
		}
	})

	addr := fmt.Sprintf(":%s", port)
	fmt.Printf("Health server listening on %s\n", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Health server error: %v\n", err)
	}
}

func mustEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		fmt.Fprintf(os.Stderr, "Required environment variable %s not set\n", key)
		os.Exit(1)
	}
	return val
}

func envOrDefault(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}
