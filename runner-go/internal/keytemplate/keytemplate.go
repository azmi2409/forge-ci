// Package keytemplate resolves CircleCI-style {{ }} template functions in
// cache keys at execution time (the compiler passes them through):
//
//	{{ checksum "path/to/file" }}  SHA256 hex of the file's contents,
//	                               relative to the job working directory;
//	                               missing/unreadable file -> "" (warned)
//	{{ .Branch }}                  the pipeline branch
//	{{ epoch }}                    current unix time (seconds)
//
// Anything else inside {{ }} is left as-is with a warning.
package keytemplate

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	templateRe = regexp.MustCompile(`\{\{\s*(.+?)\s*\}\}`)
	checksumRe = regexp.MustCompile(`\Achecksum\s+"([^"]+)"\z`)
)

// Checksum takes a path relative to the job working directory and returns
// the hex SHA256 of the file inside the container, or "" when missing or
// unreadable. Production passes a docker-exec implementation; tests pass
// whatever they like.
type Checksum func(relativePath string) string

type Options struct {
	Branch   string
	Checksum Checksum
	// Epoch overrides {{ epoch }}; nil means time.Now.
	Epoch *int64
	Warn  func(msg string)
}

func Resolve(template string, o Options) string {
	warn := o.Warn
	if warn == nil {
		warn = func(string) {}
	}
	return templateRe.ReplaceAllStringFunc(template, func(match string) string {
		expr := strings.TrimSpace(templateRe.FindStringSubmatch(match)[1])
		if m := checksumRe.FindStringSubmatch(expr); m != nil {
			path := m[1]
			var hex string
			if o.Checksum != nil {
				hex = o.Checksum(path)
			}
			if hex == "" {
				warn(fmt.Sprintf("checksum: %q is missing or unreadable; using empty string", path))
				return ""
			}
			return hex
		}
		switch expr {
		case ".Branch":
			return o.Branch
		case "epoch":
			if o.Epoch != nil {
				return strconv.FormatInt(*o.Epoch, 10)
			}
			return strconv.FormatInt(time.Now().Unix(), 10)
		default:
			warn(fmt.Sprintf("unknown template %q; leaving as-is", expr))
			return "{{ " + expr + " }}"
		}
	})
}
