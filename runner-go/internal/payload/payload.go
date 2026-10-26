// Package payload defines the claim payload types from the frozen wire
// contract (runner-go/CONTRACT.md). Rails builds the payload with .compact,
// so nil top-level fields are ABSENT, not null — hence pointer fields
// wherever absence differs from zero. Steps keep their raw JSON so unknown
// types can be identified and reported without failing to decode.
package payload

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Claim is the JSON body of a 200 claim response.
type Claim struct {
	ID               int64     `json:"id"`
	Name             string    `json:"name"`
	NodeIndex        *int      `json:"node_index"`
	Parallelism      *int      `json:"parallelism"`
	WorkingDirectory string    `json:"working_directory"`
	Executor         *Executor `json:"executor"`
	Steps            []Step    `json:"steps"`
	Environment      Env       `json:"environment"`
	Pipeline         Pipeline  `json:"pipeline"`
	// Trusted is nil when the server did not send it (older servers);
	// absence means trusted. Only an explicit false is untrusted.
	Trusted          *bool       `json:"trusted"`
	WorkflowRunID    *int64      `json:"workflow_run_id"`
	ProjectID        *int64      `json:"project_id"`
	Repository       *Repository `json:"repository"`
	DockerBuildCache *BuildCache `json:"docker_build_cache"`
}

// TrustedPipeline reports whether setup_remote_docker may use the host's
// Docker: absent trusted (older servers) and explicit true are trusted.
func (c *Claim) TrustedPipeline() bool {
	return c.Trusted == nil || *c.Trusted
}

// Parallel is the job's parallelism, defaulting to 1 like the Ruby runner.
func (c *Claim) Parallel() int {
	if c.Parallelism != nil && *c.Parallelism > 0 {
		return *c.Parallelism
	}
	return 1
}

// Node is the job's node index, defaulting to 0.
func (c *Claim) Node() int {
	if c.NodeIndex != nil && *c.NodeIndex >= 0 {
		return *c.NodeIndex
	}
	return 0
}

type Pipeline struct {
	SHA    string  `json:"sha"`
	Branch *string `json:"branch"` // null or absent on detached/unknown
}

type Executor struct {
	Image           string         `json:"image"`
	Entrypoint      *string        `json:"entrypoint"`
	Command         *string        `json:"command"`
	Environment     Env            `json:"environment"`
	ResourceClass   *string        `json:"resource_class"`
	SecondaryImages []ServiceImage `json:"secondary_images"` // null tolerated as none
}

type ServiceImage struct {
	Image       string  `json:"image"`
	Name        *string `json:"name"`
	Entrypoint  *string `json:"entrypoint"`
	Command     *string `json:"command"`
	Environment Env     `json:"environment"`
}

type Repository struct {
	URL    string  `json:"url"`
	SHA    *string `json:"sha"`
	Branch *string `json:"branch"`
	// Token is the GitHub App installation token, omitted when none. It is
	// only ever used as an http.extraHeader on the one fetch exec — never
	// in a step environment, never logged (the redactor seeds it).
	Token *string `json:"token"`
}

type BuildCache struct {
	Registry string `json:"registry"`
	Ref      string `json:"ref"`
	// Username/Password are omitted for unauthenticated registries (ECR
	// mint failure, static pair unset). nil means skip docker login.
	Username *string `json:"username"`
	Password *string `json:"password"`
}

// Step is one IR step. Known fields are typed; the whole raw JSON is kept
// so skipped unknown steps can be identified and reported.
type Step struct {
	Raw  json.RawMessage
	Type string

	Name            *string
	Command         *string
	Shell           *string
	Background      bool
	When            string // decoded default "on_success"; "" tolerated
	Environment     Env
	NoOutputTimeout *string

	Path         *string
	Destination  *string
	Keys         []string // save_cache: keys || key; restore_cache: keys
	Paths        []string
	Root         *string
	At           *string
	LayerCaching bool // setup_remote_docker with docker_layer_caching: true
}

// DisplayName follows the server convention step["name"] || step["type"].
func (s *Step) DisplayName() string {
	if s.Name != nil && *s.Name != "" {
		return *s.Name
	}
	if s.Type != "" {
		return s.Type
	}
	return "step"
}

// stepJSON mirrors Step for decoding.
type stepJSON struct {
	Type            string   `json:"type"`
	Name            *string  `json:"name"`
	Command         *string  `json:"command"`
	Shell           *string  `json:"shell"`
	Background      bool     `json:"background"`
	When            *string  `json:"when"`
	Environment     Env      `json:"environment"`
	NoOutputTimeout *string  `json:"no_output_timeout"`
	Path            *string  `json:"path"`
	Destination     *string  `json:"destination"`
	Keys            []string `json:"keys"`
	Key             *string  `json:"key"`
	Paths           []string `json:"paths"`
	Root            *string  `json:"root"`
	At              *string  `json:"at"`
	LayerCaching    bool     `json:"layer_caching"`
}

func (s *Step) UnmarshalJSON(data []byte) error {
	s.Raw = append(json.RawMessage(nil), data...)
	var v stepJSON
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&v); err != nil {
		// A step that is not a JSON object (or is malformed) is preserved as
		// raw and reported as an unknown step type — never fatal.
		s.Type = ""
		return nil
	}
	s.Type = v.Type
	s.Name = v.Name
	s.Command = v.Command
	s.Shell = v.Shell
	s.Background = v.Background
	if v.When == nil {
		s.When = "on_success"
	} else {
		s.When = *v.When
	}
	s.Environment = v.Environment
	s.NoOutputTimeout = v.NoOutputTimeout
	s.Path = v.Path
	s.Destination = v.Destination
	s.Keys = v.Keys
	if len(s.Keys) == 0 && v.Key != nil && *v.Key != "" {
		s.Keys = []string{*v.Key}
	}
	s.Paths = v.Paths
	s.Root = v.Root
	s.At = v.At
	s.LayerCaching = v.LayerCaching
	return nil
}

// Env is the job/step environment. Values are strings (the Ruby runner
// interpolated whatever the server sent); non-string JSON values are
// stringified the way Ruby's to_s would render them after a JSON parse.
type Env map[string]string

func (e Env) Merge(other Env) Env {
	out := make(Env, len(e)+len(other))
	for k, v := range e {
		out[k] = v
	}
	for k, v := range other {
		out[k] = v
	}
	return out
}

func (e *Env) UnmarshalJSON(data []byte) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		*e = nil
		return nil
	}
	*e = Env{}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for k, v := range raw {
		(*e)[k] = stringify(v)
	}
	return nil
}

// stringify renders a decoded JSON value the way the Ruby runner's
// "#\{v\}" / to_s would: strings verbatim, true/false, integers without a
// decimal point, floats in shortest round-trip form.
func stringify(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		return strconv.FormatBool(t)
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case json.Number:
		return t.String()
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return fmt.Sprintf("%v", t)
		}
		return string(b)
	}
}

// ParseClaim decodes a claim response body. The HTTP status gate happens in
// the client; this only ever sees a 200 body. Unknown fields are ignored
// (like the Ruby runner) so a forward-compatible server never breaks decode.
func ParseClaim(data []byte) (*Claim, error) {
	var c Claim
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("claim payload: %w", err)
	}
	if c.ID == 0 {
		return nil, fmt.Errorf("claim payload has no id")
	}
	return &c, nil
}

// ExpandWorkdir expands a leading "~/" to "/root/" (CI images run as root,
// matching the Ruby runner). Returns "" for empty.
func ExpandWorkdir(path string) string {
	if path == "" {
		return ""
	}
	if strings.HasPrefix(path, "~/") {
		return "/root/" + path[2:]
	}
	return path
}
