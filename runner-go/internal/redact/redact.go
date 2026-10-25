// Package redact removes secret values from log text before it leaves the
// runner. The claim payload cannot tell secrets from plain env vars, so
// every environment value at or above the minimum length is redacted as a
// literal substring, longest values first (so "s3cr3t-value-long" is
// replaced before its prefix "s3cr3t" could partially match).
//
// This package replaces within one string; the streaming layer (logstream)
// is responsible for values split across read boundaries and retains up to
// MaxSecretLen()-1 bytes for that purpose.
package redact

import (
	"sort"
	"strings"
)

const Replacement = "[REDACTED]"

type Redactor struct {
	secrets []string
}

// New builds a redactor over the environment's values. Values shorter than
// minLength are left alone: redacting e.g. "test" or "true" would make logs
// unreadable, and real secrets are long random strings.
func New(values map[string]string, minLength int) *Redactor {
	seen := make(map[string]bool, len(values))
	var secrets []string
	for _, v := range values {
		if len(v) >= minLength && !seen[v] {
			seen[v] = true
			secrets = append(secrets, v)
		}
	}
	sort.Slice(secrets, func(i, j int) bool {
		if len(secrets[i]) != len(secrets[j]) {
			return len(secrets[i]) > len(secrets[j])
		}
		return secrets[i] < secrets[j]
	})
	return &Redactor{secrets: secrets}
}

// Redact replaces every secret occurrence in s.
func (r *Redactor) Redact(s string) string {
	for _, v := range r.secrets {
		s = strings.ReplaceAll(s, v, Replacement)
	}
	return s
}

// MaxSecretLen is the length of the longest secret, or 0 with none. The
// streaming layer retains up to MaxSecretLen()-1 bytes so a secret split
// across read boundaries is still caught.
func (r *Redactor) MaxSecretLen() int {
	if len(r.secrets) == 0 {
		return 0
	}
	return len(r.secrets[0])
}

// PatternCount is exposed for tests/debugging (never the values themselves).
func (r *Redactor) PatternCount() int { return len(r.secrets) }
