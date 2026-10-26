// Beispiel-Webapp für das Image static: nur Standardbibliothek.
//
// Erfüllt den Laufzeitvertrag aller Beispiel-Apps (shared/tests/test-runtime.sh):
// Port 8080, /healthz, Unterbefehl "healthcheck", HTTPS-Request beim Start,
// Zeitzone Europe/Berlin, sauberes Beenden bei SIGTERM.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"
	_ "time/tzdata" // static enthält keine Zeitzonendaten
)

//go:embed static
var staticFiles embed.FS

const (
	listenAddr     = ":8080"
	healthURL      = "http://127.0.0.1:8080/healthz"
	defaultStartup = "https://example.com/"
	timeZone       = "Europe/Berlin"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(logger); err != nil {
		logger.Error("abbruch", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	loc, err := time.LoadLocation(timeZone)
	if err != nil {
		return fmt.Errorf("zeitzone laden: %w", err)
	}

	// Belegt, dass das CA-Bundle des Images funktioniert.
	startupURL := os.Getenv("STARTUP_URL")
	if startupURL == "" {
		startupURL = defaultStartup
	}
	if err := checkHTTPS(startupURL); err != nil {
		return fmt.Errorf("startup https %s: %w", startupURL, err)
	}
	logger.Info("startup https ok", "url", startupURL)

	site, err := fs.Sub(staticFiles, "static")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(site))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"status":     "ok",
			"runtime":    runtime.Version(),
			"uid":        os.Getuid(),
			"gid":        os.Getgid(),
			"tz":         timeZone,
			"local_time": time.Now().In(loc).Format(time.RFC3339),
		})
	})

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServe() }()
	logger.Info("listening", "addr", listenAddr)

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutdown requested")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	logger.Info("shutdown complete")
	return nil
}

func checkHTTPS(url string) error {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 500 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func healthcheck() int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(healthURL)
	if err != nil {
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
