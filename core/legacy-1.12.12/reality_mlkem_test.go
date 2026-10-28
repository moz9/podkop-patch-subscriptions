//go:build with_utls

package tls

import (
 "context"
 "crypto/ecdh"
 "crypto/rand"
 "encoding/base64"
 "encoding/binary"
 "io"
 "net"
 "testing"
 "time"

 "github.com/sagernet/sing-box/option"
)

func TestRealityChromeHybridClientHello(t *testing.T) {
 key, err := ecdh.X25519().GenerateKey(rand.Reader)
 if err != nil { t.Fatal(err) }
 cfg, err := NewRealityClient(context.Background(), "127.0.0.1", option.OutboundTLSOptions{
  Enabled:true, ServerName:"example.com",
  UTLS:&option.OutboundUTLSOptions{Enabled:true,Fingerprint:"chrome"},
  Reality:&option.OutboundRealityOptions{Enabled:true,PublicKey:base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),ShortID:"0123456789abcdef"},
 })
 if err != nil { t.Fatal(err) }
 client, server := net.Pipe()
 defer client.Close(); defer server.Close()
 ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second);defer cancel()
 done:=make(chan error,1)
 go func(){_,err:=cfg.ClientHandshake(ctx,client);done<-err}()
 server.SetReadDeadline(time.Now().Add(3*time.Second))
 header:=make([]byte,5)
 if _,err=io.ReadFull(server,header);err!=nil{t.Fatal(err)}
 if header[0]!=22{t.Fatalf("not TLS handshake record: %d",header[0])}
 hello:=make([]byte,int(binary.BigEndian.Uint16(header[3:5])))
 if _,err=io.ReadFull(server,hello);err!=nil{t.Fatal(err)}
 server.Close()
 select {case <-done: case <-time.After(3*time.Second):t.Fatal("client did not exit after closed peer")}
 offset:=0
 take:=func(n int)[]byte{if offset+n>len(hello){t.Fatal("truncated ClientHello")};v:=hello[offset:offset+n];offset+=n;return v}
 take(4+2+32)
 take(int(take(1)[0]))
 take(int(binary.BigEndian.Uint16(take(2))))
 take(int(take(1)[0]))
 extensionSize:=int(binary.BigEndian.Uint16(take(2)))
 end:=offset+extensionSize
 hasSupportedHybrid,hasHybrid,hasClassical:=false,false,false
 for offset<end {
  extension:=binary.BigEndian.Uint16(take(2)); body:=take(int(binary.BigEndian.Uint16(take(2))))
  if extension==10 {for i:=2;i+1<len(body);i+=2{if binary.BigEndian.Uint16(body[i:i+2])==4588{hasSupportedHybrid=true}}}
  if extension!=51{continue}
  for i:=2;i+3<len(body);{
   group:=binary.BigEndian.Uint16(body[i:i+2]);size:=int(binary.BigEndian.Uint16(body[i+2:i+4]));i+=4
   if i+size>len(body){t.Fatal("truncated key share")}
   if group==4588{if hasClassical||size!=1216{t.Fatal("invalid hybrid ordering/length")};hasHybrid=true}
   if group==29{hasClassical=true}
   i+=size
  }
 }
 if !hasSupportedHybrid||!hasHybrid{t.Fatal("Reality Chrome ClientHello strips X25519MLKEM768; incompatible with Xray26.9.9")}
}
