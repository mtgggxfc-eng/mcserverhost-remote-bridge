package main

import (
  "flag"
  "io"
  "log"
  "net"
  "time"
)

// Serve forwards a single public TCP connection to either internal SSH
// or internal TLS. TLS clients send a ClientHello (0x16); SSH can be server-first.
func Serve(front net.Conn, sshAddr, tlsAddr string, timeout time.Duration) {
  defer front.Close()
  one := make([]byte, 1)
  _ = front.SetReadDeadline(time.Now().Add(timeout))
  n, _ := front.Read(one)
  _ = front.SetReadDeadline(time.Time{})
  backend := sshAddr
  if n == 1 && one[0] == 0x16 { backend = tlsAddr }
  upstream, err := net.DialTimeout("tcp", backend, 3*time.Second)
  if err != nil { log.Printf("backend unreachable: %v", err); return }
  defer upstream.Close()
  if n == 1 {
    if _, err := upstream.Write(one[:1]); err != nil { return }
  }
  done := make(chan struct{}, 2)
  go func() {
    _, _ = io.Copy(upstream, front)
    if c,ok:=upstream.(*net.TCPConn);ok { _ = c.CloseWrite() }
    done <- struct{}{}
  }()
  go func() {
    _, _ = io.Copy(front, upstream)
    if c,ok:=front.(*net.TCPConn);ok { _ = c.CloseWrite() }
    done <- struct{}{}
  }()
  <-done
  _ = front.Close()
  _ = upstream.Close()
  <-done
}

func main() {
  listen := flag.String("listen", "0.0.0.0:11651", "public allocated TCP listen")
  ssh := flag.String("ssh", "127.0.0.1:21651", "internal SSH backend")
  reality := flag.String("reality", "127.0.0.1:21652", "internal sing-box REALITY backend")
  delay := flag.Duration("detect", 350*time.Millisecond, "client handshake detection delay")
  flag.Parse()
  ln,err := net.Listen("tcp",*listen)
  if err!=nil { log.Fatal(err) }
  log.Printf("mux listening at %s",ln.Addr())
  for {
    conn,err := ln.Accept()
    if err!=nil { log.Printf("accept failed: %v",err); continue }
    go Serve(conn,*ssh,*reality,*delay)
  }
}
