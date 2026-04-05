package main

import (
	"fmt"
	"sync/atomic"
	"testing"
)

func BenchmarkConnectionRegistryAdmitAndReserveSameUserParallel(b *testing.B) {
	r := newConnectionRegistry()
	resp := &admissionResponse{
		Allowed:  true,
		Username: "demo",
		Policy:   &policy{Username: "demo"},
	}
	var seq atomic.Uint64

	b.ReportAllocs()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			n := seq.Add(1)
			ip := fmt.Sprintf("10.0.%d.%d", byte(n>>8), byte(n))
			got, res, err := r.admitAndReserve("demo", ip, func(extraTotal int, extraIPs []string) (*admissionResponse, error) {
				return resp, nil
			})
			if err != nil || got == nil || res == nil {
				b.Fatalf("admitAndReserve failed: resp=%v res=%v err=%v", got, res, err)
			}
			r.finalize(res)
		}
	})
}

func BenchmarkConnectionRegistryAdmitAndReserveDistinctUsersParallel(b *testing.B) {
	r := newConnectionRegistry()
	var seq atomic.Uint64

	b.ReportAllocs()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			n := seq.Add(1)
			user := fmt.Sprintf("user-%d", n)
			resp := &admissionResponse{
				Allowed:  true,
				Username: user,
				Policy:   &policy{Username: user},
			}
			ip := fmt.Sprintf("10.1.%d.%d", byte(n>>8), byte(n))
			got, res, err := r.admitAndReserve(user, ip, func(extraTotal int, extraIPs []string) (*admissionResponse, error) {
				return resp, nil
			})
			if err != nil || got == nil || res == nil {
				b.Fatalf("admitAndReserve failed: resp=%v res=%v err=%v", got, res, err)
			}
			r.finalize(res)
		}
	})
}
