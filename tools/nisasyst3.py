#!/usr/bin/env python3
"""Nisasyst decryptor for Splatoon 2 encrypted resources (Python 3 port)."""
import sys, os, struct, zlib
from Crypto.Cipher import AES

def u32(x):
    return (x & 0xFFFFFFFF)

KEY_MATERIAL = 'e413645fa69cafe34a76192843e48cbd691d1f9fba87e8a23d40e02ce13b0d534d10301576f31bc70b763a60cf07149cfca50e2a6b3955b98f26ca84a5844a8aeca7318f8d7dba406af4e45c4806fa4d7b736d51cceaaf0e96f657bb3a8af9b175d51b9bddc1ed475677260f33c41ddbc1ee30b46c4df1b24a25cf7cb6019794'

class sead_rand:
    """Implements Splatoon 2's mersenne random generator."""
    def __init__(self, seed):
        self.seed = u32(seed)
        self.state = [self.seed]
        for i in range(1, 5):
            self.state.append(u32(0x6C078965 * (self.state[-1] ^ (self.state[-1] >> 30)) + i))
        self.state = self.state[1:]
    def get_u32(self):
        a = u32(self.state[0] ^ (self.state[0] << 11))
        self.state[0] = self.state[1]
        b = u32(self.state[3])
        c = u32(a ^ (a >> 8) ^ b ^ (b >> 19))
        self.state[1] = self.state[2]
        self.state[2] = b
        self.state[3] = c
        return c

def decrypt_resource(path, fn, out_path=None):
    if not out_path:
        out_path = '%s.dec' % path
    with open(path, 'rb') as f:
        dat = f.read()
    if dat[-8:] != b'nisasyst':
        raise ValueError('Error: Input appears not to be an encrypted Splatoon 2 archive!')
    seed = u32(zlib.crc32(fn.encode('utf-8')))
    key_iv_hex = ''
    rnd = sead_rand(seed)
    for _ in range(0x40):
        key_iv_hex += KEY_MATERIAL[(rnd.get_u32() >> 24)]
    key_iv = bytes.fromhex(key_iv_hex)
    key, iv = key_iv[:0x10], key_iv[0x10:]
    with open(out_path, 'wb') as f:
        f.write(AES.new(key, AES.MODE_CBC, iv).decrypt(dat[:-8]))
    print('Decrypted %s to %s' % (path, out_path))

def main():
    argc = len(sys.argv)
    if argc == 3:
        decrypt_resource(sys.argv[1], sys.argv[2])
    elif argc == 4:
        decrypt_resource(sys.argv[1], sys.argv[2], sys.argv[3])
    else:
        print('Usage: %s in_file resource_path [out_file]' % sys.argv[0])
        print('Example: %s ActorDb.230.byml Mush/ActorDb.release.byml' % sys.argv[0])

if __name__ == '__main__':
    main()
