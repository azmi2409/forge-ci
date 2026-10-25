package backoff

import "testing"

func TestTickAdvancesAndCaps(t *testing.T) {
	b := New(5, 60)
	want := []float64{5, 10, 20, 40, 60, 60, 60}
	for i, w := range want {
		if got := b.Tick(); got != w {
			t.Fatalf("tick %d = %v want %v", i, got, w)
		}
	}
}

func TestReset(t *testing.T) {
	b := New(5, 60)
	for i := 0; i < 4; i++ {
		b.Tick()
	}
	b.Reset()
	if b.Current() != 5 {
		t.Fatalf("after reset: %v", b.Current())
	}
}

func TestCustomFactor(t *testing.T) {
	b := NewFactor(1, 10, 3)
	want := []float64{1, 3, 9, 10, 10}
	for i, w := range want {
		if got := b.Tick(); got != w {
			t.Fatalf("tick %d = %v want %v", i, got, w)
		}
	}
}
