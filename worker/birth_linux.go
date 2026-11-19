//go:build linux

package main

import (
	"os"
	"syscall"
	"time"
)

// birth is when a file was created; Linux's stat doesn't say in Go, so its last status change stands in
// (agy creates a conversation's database once and only writes its -wal afterwards).
func birth(info os.FileInfo) time.Time {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return time.Unix(st.Ctim.Sec, st.Ctim.Nsec)
	}
	return info.ModTime()
}
