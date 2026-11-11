import socket,struct

def transfer(data):
    s=socket.create_connection(('127.0.0.1',22444),3)
    s.settimeout(4)
    s.sendall(b'\x05\x01\x02')
    assert s.recv(2)==b'\x05\x02'
    user=b'tester';password=b'test-password'
    s.sendall(b'\x01'+bytes([len(user)])+user+bytes([len(password)])+password)
    assert s.recv(2)==b'\x01\x00'
    s.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('8.8.4.4')+struct.pack('!H',18082))
    assert s.recv(10)[:2]==b'\x05\x00'
    s.sendall(data)
    try:return s.recv(4096)
    except (ConnectionResetError,TimeoutError):return b''
    finally:s.close()

plain=b'plain-fixture-data'*20
assert transfer(plain)==plain
handshake=b'\x13BitTorrent protocol'+b'\x00'*8+b'a'*20+b'b'*20
assert transfer(handshake)==b'', 'BitTorrent handshake was not blocked'
print('PASS: BitTorrent handshake blocked while plain TCP echo passes')
