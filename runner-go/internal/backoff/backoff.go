// Package backoff is the idle poll backoff: tick returns the interval to
// sleep now, then advances (base, base*factor, ... capped at max). Reset
// returns to base after a successful claim. Pure timing logic — the caller
// sleeps.
package backoff

type Backoff struct {
	base, max, factor float64
	current           float64
}

func New(base, max float64) *Backoff {
	return NewFactor(base, max, 2.0)
}

func NewFactor(base, max, factor float64) *Backoff {
	if factor <= 0 {
		factor = 2.0
	}
	return &Backoff{base: base, max: max, factor: factor, current: base}
}

func (b *Backoff) Tick() float64 {
	interval := b.current
	next := b.current * b.factor
	if next > b.max {
		next = b.max
	}
	b.current = next
	return interval
}

func (b *Backoff) Reset() { b.current = b.base }

func (b *Backoff) Current() float64 { return b.current }
