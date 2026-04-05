package wsproxy

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

const (
	OpContinuation byte = 0x0
	OpText         byte = 0x1
	OpBinary       byte = 0x2
	OpClose        byte = 0x8
	OpPing         byte = 0x9
	OpPong         byte = 0xA
)

type WSWriter struct {
	conn net.Conn
	mu   sync.Mutex
}

func NewWSWriter(conn net.Conn) *WSWriter {
	return &WSWriter{conn: conn}
}

func (w *WSWriter) writeFrame(opcode byte, payload []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	header := make([]byte, 0, 14)
	header = append(header, 0x80|opcode)
	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	case len(payload) <= 65535:
		header = append(header, 126)
		var ext [2]byte
		binary.BigEndian.PutUint16(ext[:], uint16(len(payload)))
		header = append(header, ext[:]...)
	default:
		header = append(header, 127)
		var ext [8]byte
		binary.BigEndian.PutUint64(ext[:], uint64(len(payload)))
		header = append(header, ext[:]...)
	}
	if _, err := w.conn.Write(header); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.conn.Write(payload)
	return err
}

func (w *WSWriter) WriteBinary(payload []byte) error { return w.writeFrame(OpBinary, payload) }
func (w *WSWriter) WritePong(payload []byte) error   { return w.writeFrame(OpPong, payload) }
func (w *WSWriter) WriteClose() error                { return w.writeFrame(OpClose, nil) }

type WSFrame struct {
	Opcode  byte
	Payload []byte
}

func ReadWSFrame(r *bufio.Reader) (*WSFrame, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	opcode := hdr[0] & 0x0F
	masked := hdr[1]&0x80 != 0
	if !masked {
		return nil, errors.New("client frame not masked")
	}
	payloadLen := uint64(hdr[1] & 0x7F)
	switch payloadLen {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return nil, err
		}
		payloadLen = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return nil, err
		}
		payloadLen = binary.BigEndian.Uint64(ext[:])
	}
	var mask [4]byte
	if _, err := io.ReadFull(r, mask[:]); err != nil {
		return nil, err
	}
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return &WSFrame{Opcode: opcode, Payload: payload}, nil
}
