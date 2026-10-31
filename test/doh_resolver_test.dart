// 备用 DNS 解析（DoH）的纯逻辑测试。
//
// 重点在**安全相关**的两个校验：
//   1) `isPublicIpv4` 必须挡住回环 / 内网 / CGNAT / 组播 ——
//      DNS 结果来自外部，不能把连接带到本机或内网（DNS rebinding）；
//   2) DoH 响应解析必须能识别失败（Status != 0）与非 A 记录，
//      不能把垃圾字符串当成 IP 去连。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/doh_resolver.dart';

void main() {
  group('isPublicIpv4 白名单', () {
    test('正常公网地址放行', () {
      for (final ip in [
        '1.1.1.1',
        '8.8.8.8',
        '120.92.1.2',
        '203.0.113.10',
        '223.5.5.5',
      ]) {
        expect(isPublicIpv4(ip), isTrue, reason: '$ip 应该放行');
      }
    });

    test('★ 回环 / 内网 / link-local / CGNAT / 组播 全部挡掉', () {
      for (final ip in [
        '0.0.0.0',
        '10.0.0.1',
        '10.255.255.254',
        '127.0.0.1',
        '169.254.1.1',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '100.64.0.1', // 运营商 CGNAT
        '100.127.255.1',
        '224.0.0.1', // 组播
        '239.255.255.250',
        '255.255.255.255',
      ]) {
        expect(isPublicIpv4(ip), isFalse, reason: '$ip 必须挡掉');
      }
    });

    test('172.32.x 不在内网段（边界不能误伤）', () {
      expect(isPublicIpv4('172.32.0.1'), isTrue);
      expect(isPublicIpv4('172.15.0.1'), isTrue);
    });

    test('非法输入不抛异常', () {
      for (final s in [
        '',
        'abc',
        '1.2.3',
        '1.2.3.4.5',
        '256.1.1.1',
        '1.2.3.-4',
        '2001:db8::1',
      ]) {
        expect(isPublicIpv4(s), isFalse, reason: '「$s」不是合法公网 IPv4');
      }
    });

    test('前后空白会被 trim（DoH 文本接口常带换行）', () {
      expect(isPublicIpv4('1.2.3.4\n'), isTrue);
      expect(isPublicIpv4(' 1.2.3.4 '), isTrue);
    });
  });

  group('阿里 DNS JSON 解析', () {
    test('取第一条 A 记录', () {
      const body = '{"Status":0,"TC":false,"Answer":['
          '{"name":"open.bigmodel.cn.","type":5,"TTL":60,"data":"open.bigmodel.cn.cdn.ali.com."},'
          '{"name":"open.bigmodel.cn.","type":1,"TTL":60,"data":"120.92.1.2"}]}';
      expect(pickIpv4FromAliJson(body), '120.92.1.2');
    });

    test('跳过非公网 / 非 A 记录，取后面那条合法的', () {
      const body = '{"Status":0,"Answer":['
          '{"type":1,"data":"10.0.0.1"},'
          '{"type":1,"data":"120.92.1.2"}]}';
      expect(pickIpv4FromAliJson(body), '120.92.1.2');
    });

    test('Status != 0（NXDOMAIN / 解析失败）→ null', () {
      expect(pickIpv4FromAliJson('{"Status":3,"Answer":[]}'), isNull);
    });

    test('没有 Answer / 全是 CNAME → null', () {
      expect(pickIpv4FromAliJson('{"Status":0}'), isNull);
      expect(
        pickIpv4FromAliJson('{"Status":0,"Answer":[{"type":5,"data":"a.b."}]}'),
        isNull,
      );
    });

    test('非 JSON / 空 → null（不能抛异常）', () {
      expect(pickIpv4FromAliJson(''), isNull);
      expect(pickIpv4FromAliJson('   '), isNull);
      expect(pickIpv4FromAliJson(null), isNull);
      expect(pickIpv4FromAliJson('<html>503</html>'), isNull);
    });
  });

  group('DNSPod 纯文本解析', () {
    test('单条与多条', () {
      expect(pickIpv4FromDnspod('120.92.1.2'), '120.92.1.2');
      expect(pickIpv4FromDnspod('120.92.1.2;120.92.1.3'), '120.92.1.2');
    });

    test('★ 跳过内网地址，取后面那条合法的', () {
      expect(pickIpv4FromDnspod('192.168.1.1;120.92.1.2'), '120.92.1.2');
    });

    test('错误文案 / 空 → null', () {
      expect(pickIpv4FromDnspod(''), isNull);
      expect(pickIpv4FromDnspod(null), isNull);
      expect(pickIpv4FromDnspod('no record'), isNull);
    });
  });

  group('isHostLookupFailure 归类', () {
    test('★ Android/Linux 的 Failed host lookup 要能识别', () {
      expect(
        isHostLookupFailure(SocketException(
          "Failed host lookup: 'open.bigmodel.cn'",
          osError: const OSError('No address associated with hostname', 7),
        )),
        isTrue,
      );
    });

    test('macOS / glibc 措辞也要识别', () {
      expect(
        isHostLookupFailure(SocketException('nodename nor servname provided')),
        isTrue,
      );
      expect(
        isHostLookupFailure(SocketException('Name or service not known')),
        isTrue,
      );
      expect(
        isHostLookupFailure(
            SocketException('Temporary failure in name resolution')),
        isTrue,
      );
    });

    test('"连接被拒绝"这类不是 DNS 问题，不能误判成 DNS', () {
      expect(
        isHostLookupFailure(SocketException(
          'Connection refused',
          osError: const OSError('Connection refused', 111),
        )),
        isFalse,
      );
      expect(
        isHostLookupFailure(SocketException('Software caused connection abort')),
        isFalse,
      );
    });
  });
}
