using System;
using System.Text;
using System.Collections.Generic;

// 用 C# 精确复刻 ios/Sources/Net/Digest.swift 的纯 Swift MD5 实现。
// 逐行对应同一套算法与常数表。C# 的 uint 溢出是模 2^32 环绕，
// 与 Swift 的 &+ 语义完全一致，所以这里通过就说明 Swift 那份也对。
// 刻意只用 C# 5 语法，以便用系统自带的 csc.exe 编译。

public static class MD5Verify {
    static readonly uint[] Shifts = {
        7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
        5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
        4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
        6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
    };

    static readonly uint[] Table = {
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
    };

    // C# 对 uint 的移位运算符只接受 int 位数，这里显式转换。
    // 掩码 0xFFFFFFFF 强制截断到 32 位，与 Swift 的 &<< / &>> 语义一致。
    static uint RotL(uint v, uint n) {
        // C# 要求移位位数为 int，但被移位的值必须保持 uint。
        // 之前写成 int vi = (int)v 是错的：左移溢出后 vi 变负数，
        // 再右移时按符号扩展，结果完全不对（实测所有向量都不匹配）。
        int ni = (int)n;
        return (v << ni) | (v >> (32 - ni));
    }

    public static string Hash(byte[] message) {
        uint a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

        List<byte> padded = new List<byte>(message);
        ulong bitLen = (ulong)message.Length * 8;
        padded.Add(0x80);
        while (padded.Count % 64 != 56) padded.Add(0);
        for (int i = 0; i < 8; i++) padded.Add((byte)((bitLen >> (i * 8)) & 0xFF));

        for (int start = 0; start < padded.Count; start += 64) {
            uint[] m = new uint[16];
            for (int j = 0; j < 16; j++) {
                int bi = start + j * 4;
                m[j] = (uint)(padded[bi] | (padded[bi+1] << 8) | (padded[bi+2] << 16) | (padded[bi+3] << 24));
            }
            uint a = a0, bb = b0, c = c0, d = d0;
            for (int i = 0; i < 64; i++) {
                uint f; int g;
                if (i < 16)      { f = (bb & c) | (~bb & d); g = i; }
                else if (i < 32) { f = (d & bb) | (~d & c); g = (5 * i + 1) % 16; }
                else if (i < 48) { f = bb ^ c ^ d;          g = (3 * i + 5) % 16; }
                else             { f = c ^ (bb | ~d);       g = (7 * i) % 16; }
                f = f + a + Table[i] + m[g];
                a = d; d = c; c = bb;
                bb = bb + RotL(f, Shifts[i]);
            }
            a0 += a; b0 += bb; c0 += c; d0 += d;
        }

        StringBuilder sb = new StringBuilder();
        uint[] words = new uint[] { a0, b0, c0, d0 };
        for (int w = 0; w < words.Length; w++)
            for (int s = 0; s < 32; s += 8)
                sb.Append(((words[w] >> s) & 0xFF).ToString("x2"));
        return sb.ToString();
    }

    static int Main() {
        int pass = 0, fail = 0;

        string[] inputs = new string[] {
            "",
            "a",
            "abc",
            "message digest",
            "abcdefghijklmnopqrstuvwxyz",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            "12345678901234567890123456789012345678901234567890123456789012345678901234567890"
        };
        string[] expected = new string[] {
            "d41d8cd98f00b204e9800998ecf8427e",
            "0cc175b9c0f1b6a831c399e269772661",
            "900150983cd24fb0d6963f7d28e17f72",
            "f96b697d7cb7938d525a2f31aaf161d0",
            "c3fcd3d76192e4007dfb496cca67e13b",
            "d174ab98d277d9f5a5611c2c9f419d9f",
            "57edf4a22be3c955ac49da2e2107b67a"
        };

        Console.WriteLine("--- RFC 1321 标准测试向量 ---");
        for (int i = 0; i < inputs.Length; i++) {
            string actual = Hash(Encoding.UTF8.GetBytes(inputs[i]));
            if (actual == expected[i]) { pass++; Console.WriteLine("  PASS  " + actual); }
            else { fail++; Console.WriteLine("  FAIL  期望 " + expected[i] + "  实际 " + actual); }
        }

        Console.WriteLine();
        Console.WriteLine("--- 跨分组边界（对照系统 MD5）---");
        int[] lens = new int[] { 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000 };
        for (int i = 0; i < lens.Length; i++) {
            byte[] bytes = Encoding.UTF8.GetBytes(new string('x', lens[i]));
            string actual = Hash(bytes);
            using (var md5 = System.Security.Cryptography.MD5.Create()) {
                string sys = BitConverter.ToString(md5.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
                if (actual == sys) { pass++; Console.WriteLine("  PASS  len=" + lens[i]); }
                else { fail++; Console.WriteLine("  FAIL  len=" + lens[i] + " 期望 " + sys + " 实际 " + actual); }
            }
        }

        Console.WriteLine();
        Console.WriteLine("--- 酷狗真实签名串（确认协议实际用法）---");
        string[] kgInputs = new string[] {
            "y9tjae~n)k)vn[8f7350a0196bf145b049a30b9fa268174y9tjae~n)k)vn[8",
            "9f882de24a9c98fe3f793b0cecfd3b421005y9tjae~n)k)vn[8"
        };
        for (int i = 0; i < kgInputs.Length; i++) {
            string actual = Hash(Encoding.UTF8.GetBytes(kgInputs[i]));
            using (var md5 = System.Security.Cryptography.MD5.Create()) {
                string sys = BitConverter.ToString(md5.ComputeHash(Encoding.UTF8.GetBytes(kgInputs[i]))).Replace("-", "").ToLowerInvariant();
                if (actual == sys) { pass++; Console.WriteLine("  PASS  " + actual); }
                else { fail++; Console.WriteLine("  FAIL  期望 " + sys + " 实际 " + actual); }
            }
        }

        Console.WriteLine();
        Console.WriteLine("=== 通过 " + pass + " / 失败 " + fail + " ===");
        return fail > 0 ? 1 : 0;
    }
}
