package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Codex and agy keep their own records; these read them the way Studio does on the Mac, so a worker reports
// the same status for every agent: working, idle, waiting (approval), with titles and last replies.

func home() string { h, _ := os.UserHomeDir(); return h }

func codexHome() string {
	if d := os.Getenv("CODEX_HOME"); d != "" {
		return d
	}
	return filepath.Join(home(), ".codex")
}

func sameDir(a, b string) bool {
	clean := func(p string) string {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			p = r
		}
		return strings.TrimPrefix(filepath.Clean(p), "/private")
	}
	return clean(a) == clean(b)
}

// codexStatus finds the rollout the session's Codex is writing (begun in its folder since it started) and reads
// its state: a turn started and not completed is working; an approval prompt on screen is waiting.
func codexStatus(s *session) {
	s.Status = "starting"
	var best string
	var bestTime time.Time
	_ = filepath.WalkDir(filepath.Join(codexHome(), "sessions"), func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".jsonl") || !strings.Contains(filepath.Base(p), "rollout-") {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(s.Created.Add(-3*time.Second)) {
			return nil
		}
		cwd, started := rolloutMeta(p)
		if cwd == "" || !sameDir(cwd, s.Cwd) || started.Before(s.Created.Add(-3*time.Second)) {
			return nil
		}
		if best == "" || started.Before(bestTime) {
			best, bestTime = p, started
		}
		return nil
	})
	if best == "" {
		if asking(screen(s.ID)) {
			s.Status = "waiting"
		}
		return
	}
	f, err := os.Open(best)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	busy := false
	for sc.Scan() {
		var o struct {
			Type    string `json:"type"`
			Payload struct {
				Type         string `json:"type"`
				ID           string `json:"id"`
				LastAgentMsg string `json:"last_agent_message"`
				Item         struct {
					Type    string `json:"type"`
					Content []struct {
						Text string `json:"text"`
					} `json:"content"`
				} `json:"item"`
			} `json:"payload"`
		}
		if json.Unmarshal(sc.Bytes(), &o) != nil {
			continue
		}
		switch {
		case o.Type == "session_meta":
			s.Convo = o.Payload.ID
		case o.Payload.Type == "task_started":
			busy = true
		case o.Payload.Type == "task_complete" || o.Payload.Type == "turn_aborted":
			busy = false
			if o.Payload.LastAgentMsg != "" {
				s.LastReply = o.Payload.LastAgentMsg
			}
		case o.Payload.Type == "item_completed" && o.Payload.Item.Type == "UserMessage" && s.Title == "":
			for _, c := range o.Payload.Item.Content {
				if strings.TrimSpace(c.Text) != "" {
					s.Title = truncate(strings.SplitN(strings.TrimSpace(c.Text), "\n", 2)[0], 80)
					break
				}
			}
		}
	}
	if n := codexThreadName(s.Convo); n != "" {
		s.Title = n
	}
	switch {
	case busy && asking(screen(s.ID)):
		s.Status = "waiting"
		s.Waiting = "approval"
	case busy:
		s.Status = "working"
	default:
		s.Status = "idle"
	}
}

func rolloutMeta(p string) (cwd string, started time.Time) {
	f, err := os.Open(p)
	if err != nil {
		return "", started
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 1<<16)
	line, _ := r.ReadBytes('\n')
	var o struct {
		Type    string `json:"type"`
		Payload struct {
			Cwd       string `json:"cwd"`
			Timestamp string `json:"timestamp"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &o) != nil || o.Type != "session_meta" {
		return "", started
	}
	started, _ = time.Parse(time.RFC3339Nano, o.Payload.Timestamp)
	return o.Payload.Cwd, started
}

func codexThreadName(id string) string {
	if id == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(codexHome(), "session_index.jsonl"))
	if err != nil {
		return ""
	}
	name := ""
	for _, line := range strings.Split(string(b), "\n") {
		var o struct {
			ID   string `json:"id"`
			Name string `json:"thread_name"`
		}
		if json.Unmarshal([]byte(line), &o) == nil && o.ID == id && o.Name != "" {
			name = o.Name
		}
	}
	return name
}

// asking: Codex's approval prompts ask "Would you like to …?" above "Yes, …" choices; it doesn't log them.
func asking(scr string) bool {
	i := strings.LastIndex(scr, "Would you like to ")
	return i >= 0 && strings.Contains(scr[i:], "Yes, ") && (strings.Contains(scr[i:], "No, ") || strings.Contains(scr[i:], "esc"))
}

// agy keeps each conversation in a SQLite database. The worker is built without cgo, so it reads them with
// the sqlite3 command when the machine has it (most do); otherwise agy sessions report running or exited.
func agyStatus(s *session) {
	s.Status = "running"
	if _, err := exec.LookPath("sqlite3"); err != nil {
		return
	}
	dir := filepath.Join(home(), ".gemini", "antigravity-cli", "conversations")
	dbs, _ := filepath.Glob(filepath.Join(dir, "*.db"))
	var best string
	var bestTime time.Time
	for _, p := range dbs {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		created := birth(info)
		if created.Before(s.Created.Add(-3 * time.Second)) {
			continue
		}
		if ws := agyWorkspace(p); ws == "" || !sameDir(ws, s.Cwd) {
			continue
		}
		if best == "" || created.Before(bestTime) {
			best, bestTime = p, created
		}
	}
	if best == "" {
		s.Status = "starting"
		return
	}
	s.Convo = strings.TrimSuffix(filepath.Base(best), ".db")
	out := sqlite(best, "SELECT status FROM steps WHERE status != 3")
	statuses := strings.Fields(out)
	has := func(v string) bool {
		for _, x := range statuses {
			if x == v {
				return true
			}
		}
		return false
	}
	// between steps every step reads done for a moment: still working if it was seconds ago (agy also writes
	// its database while idle, so file times can't tell)
	running := has("2") || has("8") // running a command, generating
	agyMu.Lock()
	if running {
		agyLastBusy[s.Convo] = time.Now()
	}
	recent := time.Since(agyLastBusy[s.Convo]) < 4*time.Second
	agyMu.Unlock()
	switch {
	case has("9"): // waiting for permission
		s.Status, s.Waiting = "waiting", "permission"
	case running || recent:
		s.Status = "working"
	default:
		s.Status = "idle"
	}
	s.LastReply = agyLastReply(best)
}

var (
	agyMu       sync.Mutex
	agyLastBusy = map[string]time.Time{}
)

// agyLastReply: agy records each model call's whole conversation in gen_metadata (field 1 → 2 → 3 holds the
// turns in order; the user's are wrapped in <USER_REQUEST>): the last plain one is the reply.
func agyLastReply(db string) string {
	b, err := hex.DecodeString(strings.TrimSpace(sqlite(db, "SELECT hex(data) FROM gen_metadata ORDER BY idx DESC LIMIT 1")))
	if err != nil {
		return ""
	}
	reply := ""
	for _, s := range protoAt(b, []int{1, 2, 3}) {
		t := strings.TrimSpace(s)
		if t != "" && !strings.HasPrefix(t, "<") {
			reply = t
		}
	}
	return reply
}

// protoAt: the string fields at a path of field numbers, every occurrence, in order.
func protoAt(b []byte, path []int) []string {
	var out []string
	i := 0
	varint := func() (uint64, bool) {
		var v uint64
		for shift := uint(0); i < len(b) && shift < 64; shift += 7 {
			c := b[i]
			i++
			v |= uint64(c&0x7f) << shift
			if c&0x80 == 0 {
				return v, true
			}
		}
		return 0, false
	}
	for i < len(b) {
		key, ok := varint()
		if !ok {
			break
		}
		switch key & 7 {
		case 0:
			if _, ok := varint(); !ok {
				return out
			}
		case 1:
			i += 8
		case 5:
			i += 4
		case 2:
			n, ok := varint()
			if !ok || n > uint64(len(b)-i) {
				return out
			}
			sub := b[i : i+int(n)]
			i += int(n)
			if int(key>>3) != path[0] {
				continue
			}
			if len(path) == 1 {
				out = append(out, string(sub))
			} else {
				out = append(out, protoAt(sub, path[1:])...)
			}
		default:
			return out
		}
	}
	return out
}

var fileURL = regexp.MustCompile(`file://[!-~]+`)

func agyWorkspace(db string) string {
	h := strings.TrimSpace(sqlite(db, "SELECT hex(data) FROM trajectory_metadata_blob LIMIT 1"))
	b, err := hex.DecodeString(h)
	if err != nil {
		return ""
	}
	m := fileURL.Find(b)
	if m == nil {
		return ""
	}
	return strings.TrimPrefix(string(m), "file://")
}

// sqlite runs a read-only query (immutable when agy doesn't have the database open: no -shm file).
func sqlite(db, query string) string {
	uri := "file:" + db + "?mode=ro"
	if _, err := os.Stat(db + "-shm"); err != nil {
		uri += "&immutable=1"
	}
	out, _ := exec.Command("sqlite3", uri, query).Output()
	return string(out)
}
