import socket,struct,sys
port=int(sys.argv[1])
control=socket.create_connection(('127.0.0.1',port),3)
control.sendall(b'\x05\x01\x00')
assert control.recv(2)==b'\x05\x00'
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
udp.bind(('127.0.0.1',0));udp.settimeout(4)
control.sendall(b'\x05\x03\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',udp.getsockname()[1]))
reply=control.recv(128)
assert reply[:2]==b'\x05\x00',reply
relay=(socket.inet_ntoa(reply[4:8]),struct.unpack('!H',reply[8:10])[0])
if relay[0]=='0.0.0.0':relay=('127.0.0.1',relay[1])
payload=b'xray-udp-fixture'
udp.sendto(b'\x00\x00\x00\x01'+socket.inet_aton('8.8.4.4')+struct.pack('!H',18081)+payload,relay)
response=udp.recv(65535)
assert response.endswith(payload),response
print('UDP round-trip OK')
