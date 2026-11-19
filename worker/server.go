package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

var sigZero = syscall.Signal(0)

func serve(c config) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, info(c)) })
	mux.HandleFunc("GET /v1/sessions", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, listSessions()) })
	mux.HandleFunc("POST /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Agent, Cwd, Prompt string }
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			httpError(w, 400, "bad JSON")
			return
		}
		if req.Agent == "" {
			req.Agent = "claude"
		}
		s, err := startSession(req.Agent, req.Cwd, req.Prompt)
		if err != nil {
			httpError(w, 400, err.Error())
			return
		}
		log.Printf("started %s (%s) in %s", s.ID, s.Agent, s.Cwd)
		writeJSON(w, s)
	})
	mux.HandleFunc("GET /v1/sessions/{id}", func(w http.ResponseWriter, r *http.Request) {
		s, ok := getSession(r.PathValue("id"))
		if !ok {
			httpError(w, 404, "no such session")
			return
		}
		writeJSON(w, s)
	})
	mux.HandleFunc("GET /v1/sessions/{id}/screen", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"screen": screen(r.PathValue("id"))})
	})
	mux.HandleFunc("POST /v1/sessions/{id}/send", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Text string }
		if json.NewDecoder(r.Body).Decode(&req) != nil || strings.TrimSpace(req.Text) == "" {
			httpError(w, 400, "text is required")
			return
		}
		if err := sendText(r.PathValue("id"), req.Text); err != nil {
			httpError(w, 400, err.Error())
			return
		}
		writeJSON(w, map[string]string{"ok": "sent"})
	})
	mux.HandleFunc("DELETE /v1/sessions/{id}", func(w http.ResponseWriter, r *http.Request) {
		if err := stopSession(r.PathValue("id")); err != nil {
			httpError(w, 404, "no such session")
			return
		}
		log.Printf("stopped %s", r.PathValue("id"))
		writeJSON(w, map[string]string{"ok": "stopped"})
	})
	mux.HandleFunc("GET /v1/sessions/{id}/attach", attach)
	mux.HandleFunc("GET /v1/dirs", func(w http.ResponseWriter, r *http.Request) {
		list, path, err := listDirs(r.URL.Query().Get("path"))
		if err != nil {
			httpError(w, 400, err.Error())
			return
		}
		writeJSON(w, map[string]any{"path": path, "dirs": list})
	})

	h := authenticate(c.Token, mux)
	log.Printf("studio-worker %s listening on %s", version, c.Addr)
	srv := &http.Server{Addr: c.Addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func authenticate(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			httpError(w, 401, "wrong or missing token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

type agentInfo struct {
	Installed bool   `json:"installed"`
	Version   string `json:"version,omitempty"`
}

func info(c config) map[string]any {
	host, _ := os.Hostname()
	home, _ := os.UserHomeDir()
	ag := map[string]agentInfo{}
	for name, bin := range agents {
		out, err := exec.Command(os.Getenv("SHELL"), "-lc", "command -v "+bin+" >/dev/null && "+bin+" --version").Output()
		if err != nil || len(out) == 0 {
			// SHELL may be unset under systemd
			out, err = exec.Command("/bin/bash", "-lc", "command -v "+bin+" >/dev/null && "+bin+" --version").Output()
		}
		v := strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0])
		ag[name] = agentInfo{Installed: err == nil && v != "", Version: strings.TrimSuffix(v, " (Claude Code)")}
	}
	return map[string]any{"name": c.Name, "hostname": host, "os": runtime.GOOS, "arch": runtime.GOARCH,
		"version": version, "home": home, "agents": ag}
}

var upgrader = websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }} // token-checked already

// attach bridges a WebSocket to `tmux attach` in a pty: binary frames carry terminal bytes both ways; a text
// frame {"cols":N,"rows":M} resizes.
func attach(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := getSession(id); !ok {
		httpError(w, 404, "no such session")
		return
	}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()
	cmd := exec.Command("tmux", tmuxArgs("attach-session", "-t", "sn-"+id)...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 120, Rows: 40})
	if err != nil {
		_ = ws.WriteMessage(websocket.TextMessage, []byte(`{"error":"`+err.Error()+`"}`))
		return
	}
	defer func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait(); _ = f.Close() }()
	log.Printf("attached %s", id)

	done := make(chan struct{})
	go func() { // pty → socket
		defer close(done)
		buf := make([]byte, 32<<10)
		for {
			n, err := f.Read(buf)
			if n > 0 {
				if ws.WriteMessage(websocket.BinaryMessage, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	go func() { // socket → pty
		for {
			kind, data, err := ws.ReadMessage()
			if err != nil {
				_ = cmd.Process.Kill()
				return
			}
			if kind == websocket.TextMessage {
				var sz struct{ Cols, Rows uint16 }
				if json.Unmarshal(data, &sz) == nil && sz.Cols > 0 && sz.Rows > 0 {
					_ = pty.Setsize(f, &pty.Winsize{Cols: sz.Cols, Rows: sz.Rows})
				}
				continue
			}
			_, _ = f.Write(data)
		}
	}()
	<-done
	log.Printf("detached %s", id)
}
