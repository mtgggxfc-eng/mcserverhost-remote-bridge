package main

import("net";"testing";"time";"io")

func backend(t *testing.T, reply string)(string,func()) {
  l,e:=net.Listen("tcp","127.0.0.1:0");if e!=nil {t.Fatal(e)}
  go func(){
    for {
      c,e:=l.Accept();if e!=nil{return}
      go func() {
        defer c.Close()
        if reply=="SSH-backend" { _,_=c.Write([]byte(reply));return }
        buf:=make([]byte,128)
        _=c.SetReadDeadline(time.Now().Add(2*time.Second))
        _,_=c.Read(buf)
        _,_=c.Write([]byte(reply))
      }()
    }
  }()
  return l.Addr().String(),func(){_ = l.Close()}
}

func TestSplit(t *testing.T){
  ssh,stop1:=backend(t,"SSH-backend");defer stop1()
  tls,stop2:=backend(t,"Reality-backend");defer stop2()
  for _,tc:=range []struct{first byte; want string; wait bool}{
    {0x16,"Reality-backend",false},
    {'S',"SSH-backend",false},
    {0,"SSH-backend",true},
  } {
    l,e:=net.Listen("tcp","127.0.0.1:0");if e!=nil{t.Fatal(e)}
    go func(){conn,e:=l.Accept();if e==nil{Serve(conn,ssh,tls,90*time.Millisecond)}}()
    c,e:=net.Dial("tcp",l.Addr().String());if e!=nil{t.Fatal(e)}
    _=c.SetDeadline(time.Now().Add(time.Second))
    if !tc.wait { _,_=c.Write([]byte{tc.first}) }
    got,_:=io.ReadAll(c)
    if string(got)!=tc.want{t.Errorf("want %s, got %q",tc.want,string(got))}
    _=c.Close();_ =l.Close()
  }
}
