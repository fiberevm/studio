package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Sessions live in tmux on a private socket, one tmux session each, named "sn-<id>". Their agent and folder are
// kept as tmux options, so the list survives studio-worker restarts with no state of its own.
const socket = "studio-worker"

var agents = map[string]string{"claude": "claude", "codex": "codex", "agy": "agy"}

type session struct {
	ID        string    `json:"id"`
	Agent     string    `json:"agent"`
	Cwd       string    `json:"cwd"`
	Created   time.Time `json:"created"`
	Running   bool      `json:"running"`
	Status    string    `json:"status"` // working | idle | waiting | starting | exited
	Title     string    `json:"title,omitempty"`
	LastReply string    `json:"lastReply,omitempty"`
	Prompt    string    `json:"prompt,omitempty"`     // the first one, as given
	Waiting   string    `json:"waitingFor,omitempty"` // what it needs from you
	Convo     string    `json:"conversation,omitempty"`
}

func tmuxConf() string {
	dir := filepath.Dir(configPath())
	_ = os.MkdirAll(dir, 0o700)
	p := filepath.Join(dir, "tmux.conf")
	// invisible tmux, like Studio's own: no status bar, no prefix, keep the pane after the agent exits so its
	// result can still be read
	conf := `set -g status off
set -g prefix None
unbind-key -a
set -g escape-time 0
set -g history-limit 50000
set -g mouse off
set -g focus-events on
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"
set -ga terminal-overrides ",xterm-256color:smcup@:rmcup@"
set -g allow-passthrough on
set -g window-size latest
set -g remain-on-exit on
set -g exit-empty off
`
	_ = os.WriteFile(p, []byte(conf), 0o600)
	return p
}

// tmuxArgs are the options every tmux call here uses: our socket and config, and -u (UTF-8 even when the
// machine has no UTF-8 locale, as under systemd; otherwise tmux turns the agents' ●, ❯ and box drawing into _).
func tmuxArgs(args ...string) []string {
	return append([]string{"-u", "-L", socket, "-f", tmuxConf()}, args...)
}

func tmux(args ...string) (string, error) {
	full := tmuxArgs(args...)
	out, err := exec.Command("tmux", full...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("_./=:-@%+", r))
	}) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func newID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// startSession runs `agent [prompt]` in a new tmux session in cwd, through the user's login shell.
func startSession(agent, cwd, prompt string) (session, error) {
	bin, ok := agents[agent]
	if !ok {
		return session{}, fmt.Errorf("unknown agent %q (claude, codex or agy)", agent)
	}
	if cwd == "" {
		cwd, _ = os.UserHomeDir()
	}
	cwd = expandHome(cwd)
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		return session{}, fmt.Errorf("no such folder: %s", cwd)
	}
	words := []string{"exec", bin}
	if prompt != "" {
		switch agent {
		case "agy":
			words = append(words, "-i", prompt)
		case "codex":
			words = append(words, "--", prompt)
		default:
			words = append(words, prompt)
		}
	}
	quoted := make([]string, len(words))
	for i, w := range words {
		quoted[i] = shellQuote(w)
	}
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/bash"
	}
	id := newID()
	name := "sn-" + id
	cmd := shell + " -l -i -c " + shellQuote(strings.Join(quoted, " "))
	if out, err := tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", cwd,
		"-e", "TERM=xterm-256color", "-e", "COLORTERM=truecolor", "-e", "STUDIO_WORKER=1", "-e", "LANG="+utf8Locale(), cmd); err != nil {
		return session{}, fmt.Errorf("tmux: %v: %s", err, out)
	}
	_, _ = tmux("set-option", "-t", name, "@agent", agent)
	_, _ = tmux("set-option", "-t", name, "@cwd", cwd)
	if prompt != "" {
		_, _ = tmux("set-option", "-t", name, "@prompt", truncate(prompt, 500))
	}
	return session{ID: id, Agent: agent, Cwd: cwd, Created: time.Now(), Running: true, Status: "starting", Prompt: prompt}, nil
}

// utf8Locale is the machine's locale if it's UTF-8, else C.UTF-8 (always present on glibc and musl systems).
func utf8Locale() string {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v := os.Getenv(k); v != "" {
			if strings.Contains(strings.ToUpper(v), "UTF-8") || strings.Contains(strings.ToUpper(v), "UTF8") {
				return v
			}
			break
		}
	}
	return "C.UTF-8"
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	return p
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// listSessions returns every session, newest first, with what each agent is doing.
func listSessions() []session {
	// tmux prints tabs (and, without a UTF-8 locale, anything non-ASCII) as "_": split on plain ASCII
	const sep = "|~|"
	out, err := tmux("list-sessions", "-F",
		"#{session_name}"+sep+"#{session_created}"+sep+"#{@agent}"+sep+"#{@cwd}"+sep+"#{pane_dead}"+sep+"#{@prompt}")
	if err != nil {
		return []session{}
	}
	live := claudeLive()
	var list []session
	for _, line := range strings.Split(out, "\n") {
		f := strings.SplitN(line, sep, 6)
		if len(f) < 6 || !strings.HasPrefix(f[0], "sn-") {
			continue
		}
		created, _ := strconv.ParseInt(f[1], 10, 64)
		s := session{ID: strings.TrimPrefix(f[0], "sn-"), Agent: f[2], Cwd: f[3], Created: time.Unix(created, 0),
			Running: f[4] != "1", Prompt: f[5]}
		if s.Agent == "" {
			s.Agent = "claude"
		}
		switch {
		case !s.Running:
			s.Status = "exited"
		case s.Agent == "claude":
			s.Status = "starting"
			if l, ok := live[f[0]]; ok {
				s.Status, s.Waiting, s.Convo = l.status, l.waitingFor, l.sessionID
			}
		case s.Agent == "codex":
			codexStatus(&s)
		case s.Agent == "agy":
			agyStatus(&s)
		default:
			s.Status = "running"
		}
		if s.Agent == "claude" && s.Convo != "" {
			s.Title, s.LastReply = transcriptSummary(s.Convo)
		}
		if s.Title == "" {
			s.Title = truncate(strings.SplitN(s.Prompt, "\n", 2)[0], 80)
		}
		list = append(list, s)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Created.After(list[j].Created) })
	if list == nil {
		list = []session{}
	}
	return list
}

func getSession(id string) (session, bool) {
	for _, s := range listSessions() {
		if s.ID == id {
			return s, true
		}
	}
	return session{}, false
}

type liveClaude struct{ status, waitingFor, sessionID string }

// claudeLive reads ~/.claude/sessions/<pid>.json: Claude Code records its status there, and the tmux session it
// runs in ("sn-1a2b3c4d:@0.%0"), which maps it to our session.
func claudeLive() map[string]liveClaude {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(claudeHome(home), "sessions")
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	out := map[string]liveClaude{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var o struct {
			PID        int    `json:"pid"`
			SessionID  string `json:"sessionId"`
			Tmux       string `json:"tmux"`
			Status     string `json:"status"`
			WaitingFor string `json:"waitingFor"`
		}
		if json.Unmarshal(b, &o) != nil || o.Tmux == "" || !alive(o.PID) {
			continue
		}
		name := strings.SplitN(o.Tmux, ":", 2)[0]
		st := map[string]string{"busy": "working", "shell": "working", "idle": "idle", "waiting": "waiting"}[o.Status]
		if st == "" {
			st = "idle"
		}
		out[name] = liveClaude{st, o.WaitingFor, o.SessionID}
	}
	return out
}

func claudeHome(home string) string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	return filepath.Join(home, ".claude")
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	return err == nil && p.Signal(sigZero) == nil
}

// transcriptSummary reads a Claude transcript's title and its last reply (from the end of the file only).
func transcriptSummary(convo string) (title, reply string) {
	home, _ := os.UserHomeDir()
	matches, _ := filepath.Glob(filepath.Join(claudeHome(home), "projects", "*", convo+".jsonl"))
	if len(matches) == 0 {
		return "", ""
	}
	f, err := os.Open(matches[0])
	if err != nil {
		return "", ""
	}
	defer f.Close()
	const tail = 512 << 10
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		_, _ = f.Seek(st.Size()-tail, io.SeekStart)
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	var first, aiTitle, custom string
	for sc.Scan() {
		line := sc.Bytes()
		if !bytes.Contains(line, []byte(`"type":"assistant"`)) && !bytes.Contains(line, []byte(`-title"`)) &&
			!bytes.Contains(line, []byte(`"type":"user"`)) {
			continue
		}
		var o struct {
			Type        string `json:"type"`
			AiTitle     string `json:"aiTitle"`
			CustomTitle string `json:"customTitle"`
			IsSidechain bool   `json:"isSidechain"`
			IsMeta      bool   `json:"isMeta"`
			Message     struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(line, &o) != nil || o.IsSidechain {
			continue
		}
		switch o.Type {
		case "ai-title":
			aiTitle = o.AiTitle
		case "custom-title":
			custom = o.CustomTitle
		case "user":
			var s string
			if first == "" && !o.IsMeta && json.Unmarshal(o.Message.Content, &s) == nil && !strings.HasPrefix(s, "<") {
				first = s
			}
		case "assistant":
			var blocks []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}
			if json.Unmarshal(o.Message.Content, &blocks) == nil {
				for _, b := range blocks {
					if b.Type == "text" && strings.TrimSpace(b.Text) != "" {
						reply = b.Text
					}
				}
			}
		}
	}
	title = custom
	if title == "" {
		title = aiTitle
	}
	if title == "" {
		title = truncate(strings.SplitN(first, "\n", 2)[0], 80)
	}
	return title, reply
}

// sendText types a message into the session's agent and presses Return: a bracketed paste (so the agent takes
// it as one input), then Return a beat later.
func sendText(id, text string) error {
	name := "sn-" + id
	if _, ok := getSession(id); !ok {
		return errors.New("no such session")
	}
	load := exec.Command("tmux", tmuxArgs("load-buffer", "-b", name, "-")...)
	load.Stdin = strings.NewReader(text)
	if out, err := load.CombinedOutput(); err != nil {
		return fmt.Errorf("tmux: %v: %s", err, out)
	}
	if out, err := tmux("paste-buffer", "-p", "-d", "-b", name, "-t", name); err != nil {
		return fmt.Errorf("tmux: %v: %s", err, out)
	}
	time.Sleep(300 * time.Millisecond)
	_, err := tmux("send-keys", "-t", name, "Enter")
	return err
}

// screen is the text on the session's screen (for agents whose detail we don't parse).
func screen(id string) string {
	out, _ := tmux("capture-pane", "-p", "-t", "sn-"+id)
	return out
}

func stopSession(id string) error {
	_, err := tmux("kill-session", "-t", "sn-"+id)
	return err
}

type dirEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Git  bool   `json:"git"`
}

// listDirs lists the folders in path (default: home), marking git repositories.
func listDirs(path string) ([]dirEntry, string, error) {
	if path == "" {
		path = "~"
	}
	path = expandHome(path)
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, path, err
	}
	out := []dirEntry{}
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		p := filepath.Join(path, e.Name())
		_, gerr := os.Stat(filepath.Join(p, ".git"))
		out = append(out, dirEntry{Name: e.Name(), Path: p, Git: gerr == nil})
	}
	return out, path, nil
}
