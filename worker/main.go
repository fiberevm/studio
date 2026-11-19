// studio-worker makes a Linux (or any Unix) machine a Studio worker: run `studio-worker serve` on it, paste the
// pairing link it prints into Studio (Settings → Workers), and Studio can start agent sessions there, show them
// in tabs, and let its AIs hand work to them. Sessions run in tmux on the machine, so they outlive the connection.
//
// It listens on plain HTTP and expects the network to be private: a Tailscale tailnet, a Cloudflare Zero Trust
// private network, a LAN. Every request needs the machine's token (Authorization: Bearer …).
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var version = "0.1.0"

type config struct {
	Name  string `json:"name"`
	Token string `json:"token"`
	Addr  string `json:"addr"`
}

func configPath() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "studio-worker", "config.json")
}

// loadConfig reads the config, creating it (with a fresh token) on first run.
func loadConfig() config {
	var c config
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	changed := false
	if c.Token == "" {
		buf := make([]byte, 24)
		_, _ = rand.Read(buf)
		c.Token = hex.EncodeToString(buf)
		changed = true
	}
	if c.Name == "" {
		c.Name, _ = os.Hostname()
		changed = true
	}
	if c.Addr == "" {
		c.Addr = ":7420"
		changed = true
	}
	if changed {
		saveConfig(c)
	}
	return c
}

func saveConfig(c config) {
	_ = os.MkdirAll(filepath.Dir(configPath()), 0o700)
	b, _ := json.MarshalIndent(c, "", "  ")
	_ = os.WriteFile(configPath(), b, 0o600)
}

func usage() {
	fmt.Fprintf(os.Stderr, `studio-worker %s — make this machine a Studio worker

Usage:
  studio-worker serve [--addr :7420] [--name NAME] [--host HOST]   run it (prints the pairing link)
  studio-worker pair [--host HOST]                                   print the pairing link again
  studio-worker install-service                                      run it in the background (systemd user service)
  studio-worker rotate-token                                         new token (re-pair Studio afterwards)
  studio-worker version

Needs tmux, and the agent CLIs you want to run (claude, codex, agy) logged in for this user.
`, version)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ExitOnError)
		addr := fs.String("addr", "", "listen address (default :7420, or the saved one)")
		name := fs.String("name", "", "name shown in Studio (default: hostname)")
		host := fs.String("host", "", "address Studio should use to reach this machine (default: guessed, Tailscale first)")
		_ = fs.Parse(args)
		c := loadConfig()
		if *addr != "" {
			c.Addr = *addr
		}
		if *name != "" {
			c.Name = *name
		}
		saveConfig(c)
		requireTmux()
		fmt.Println(pairingText(c, *host))
		serve(c)
	case "pair":
		fs := flag.NewFlagSet("pair", flag.ExitOnError)
		host := fs.String("host", "", "address Studio should use to reach this machine")
		_ = fs.Parse(args)
		fmt.Println(pairingText(loadConfig(), *host))
	case "install-service":
		installService()
	case "rotate-token":
		c := loadConfig()
		c.Token = ""
		saveConfig(c)
		c = loadConfig()
		fmt.Println("New token. Restart studio-worker, then pair Studio again:")
		fmt.Println(pairingText(c, ""))
	case "version", "--version", "-v":
		fmt.Println("studio-worker", version)
	default:
		usage()
		os.Exit(2)
	}
}

func requireTmux() {
	if _, err := exec.LookPath("tmux"); err != nil {
		fmt.Fprintln(os.Stderr, "studio-worker needs tmux (sessions live in it): install it, e.g. `sudo apt install tmux`.")
		os.Exit(1)
	}
}

// pairingLink is what Studio takes: studio://worker?url=…&token=…&name=…
func pairingLink(c config, host string) string {
	_, port, _ := net.SplitHostPort(c.Addr)
	if port == "" {
		port = "7420"
	}
	if host == "" {
		host = guessHost()
	}
	u := "http://" + net.JoinHostPort(host, port)
	q := url.Values{"url": {u}, "token": {c.Token}, "name": {c.Name}}
	return "studio://worker?" + q.Encode()
}

func pairingText(c config, host string) string {
	link := pairingLink(c, host)
	return fmt.Sprintf(`
  studio-worker %s is ready as "%s".

  In Studio: Settings → Workers → Add Worker, and paste:

    %s

  (Keep it private: the link carries this machine's token. `+"`studio-worker rotate-token`"+` revokes it.)
`, version, c.Name, link)
}

// guessHost picks the address Studio will most likely reach: a Tailscale address (100.64.0.0/10) or a
// MagicDNS name first, then any private address, then the hostname.
func guessHost() string {
	if out, err := exec.Command("tailscale", "status", "--self", "--json").Output(); err == nil {
		var st struct {
			Self struct {
				DNSName      string   `json:"DNSName"`
				TailscaleIPs []string `json:"TailscaleIPs"`
			} `json:"Self"`
		}
		if json.Unmarshal(out, &st) == nil {
			if n := strings.TrimSuffix(st.Self.DNSName, "."); n != "" {
				return n
			}
			for _, ip := range st.Self.TailscaleIPs {
				if !strings.Contains(ip, ":") {
					return ip
				}
			}
		}
	}
	var private string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.To4() == nil || ipn.IP.IsLoopback() {
			continue
		}
		ip := ipn.IP.To4()
		if ip[0] == 100 && ip[1]&0xC0 == 64 { // Tailscale CGNAT range
			return ip.String()
		}
		if private == "" && ip.IsPrivate() {
			private = ip.String()
		}
	}
	if private != "" {
		return private
	}
	h, _ := os.Hostname()
	return h
}

func installService() {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".config", "systemd", "user")
	_ = os.MkdirAll(dir, 0o755)
	// a login shell, so the agent CLIs and their PATH resolve as in a terminal
	unit := fmt.Sprintf(`[Unit]
Description=studio-worker: Studio worker
After=network-online.target

[Service]
ExecStart=/bin/bash -lc 'exec %s serve'
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
`, exe)
	path := filepath.Join(dir, "studio-worker.service")
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, args := range [][]string{{"--user", "daemon-reload"}, {"--user", "enable", "--now", "studio-worker"}} {
		if out, err := exec.Command("systemctl", args...).CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "systemctl %s: %v\n%s", strings.Join(args, " "), err, out)
			os.Exit(1)
		}
	}
	fmt.Println("Installed and started:", path)
	fmt.Println("To keep it running while you're logged out: sudo loginctl enable-linger", os.Getenv("USER"))
	fmt.Println(pairingText(loadConfig(), ""))
}
