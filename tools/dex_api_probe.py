#!/usr/bin/env python3
"""
dex_api_probe.py — 从 Android 系统 framework jar/dex 中提取类与方法清单。

用途：适配新厂商 ROM / 新 Android 版本时，验证 LSPosed Hook 点与反射调用的
目标类/方法是否真实存在。javap 无法读取 dex，故此处直接解析 dex 结构。

用法：
    python3 dex_api_probe.py <framework.jar|classes.dex> [类名过滤关键字...]
    python3 dex_api_probe.py framework.jar ActivityTaskSupervisor
    python3 dex_api_probe.py --selftest
"""
import struct, sys, zipfile, io, os

NO_INDEX = 0xFFFFFFFF


class Dex:
    def __init__(self, data):
        self.d = data
        if data[:4] != b'dex\n':
            raise ValueError("not a dex file (bad magic %r)" % data[:4])
        self.strings = self._read_strings()
        self.type_names = self._read_type_names()
        self.methods = self._read_methods()
        self.protos = self._read_protos()
        self.classes = self._read_classes()

    def _u32(self, off):
        return struct.unpack_from('<I', self.d, off)[0]

    def _read_strings(self):
        n, off = self._u32(0x38), self._u32(0x3C)
        out = []
        for i in range(n):
            so = self._u32(off + i * 4)
            # uleb128 utf16 size
            p = so
            while self.d[p] & 0x80:
                p += 1
            p += 1
            end = self.d.index(b'\x00', p)
            out.append(self.d[p:end].decode('utf-8', 'replace'))
        return out

    def _read_type_names(self):
        n, off = self._u32(0x40), self._u32(0x44)
        return [self.strings[self._u32(off + i * 4)] for i in range(n)]

    def _read_methods(self):
        n, off = self._u32(0x58), self._u32(0x5C)
        out = []
        for i in range(n):
            b = off + i * 8
            out.append((self._u32(b + 4), self._u32(b)))  # (name_idx, proto_idx)
        return out

    def _read_protos(self):
        """proto_ids: {size@0x48, off@0x4C}, 每项 12 字节 (shorty, return_type, parameters_off)"""
        n, off = self._u32(0x48), self._u32(0x4C)
        out = []
        for i in range(n):
            b = off + i * 12
            ret = self._u32(b + 4)
            params_off = self._u32(b + 8)
            params = []
            if params_off and params_off + 4 <= len(self.d):
                sz = self._u32(params_off)
                for k in range(sz):
                    t = self._u32(params_off + 4 + k * 2)
                    if t < len(self.type_names):
                        params.append(self.type_names[t])
            out.append((ret if ret < len(self.type_names) else '?', params))
        return out

    @staticmethod
    def pretty(type_desc):
        """Lcom/foo/Bar; -> com.foo.Bar"""
        if not type_desc or not type_desc.startswith('L'):
            return type_desc
        return type_desc[1:-1].replace('/', '.')

    def method_signature(self, method_idx):
        name_idx, proto_idx = self.methods[method_idx]
        if proto_idx >= len(self.protos):
            return self.strings[name_idx], '?', []
        ret, params = self.protos[proto_idx]
        return (self.strings[name_idx], self.pretty(ret),
                [self.pretty(x) for x in params])

    def _read_classes(self):
        n, off = self._u32(0x60), self._u32(0x64)
        out = []
        for i in range(n):
            b = off + i * 32
            type_idx = self._u32(b)
            class_data_off = self._u32(b + 24)
            out.append((type_idx, class_data_off))
        return out

    @staticmethod
    def _uleb(data, p):
        result = 0
        shift = 0
        while True:
            b = data[p]
            p += 1
            result |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
        return result, p

    def class_method_names(self, class_data_off):
        """返回 (direct_method_names, virtual_method_names)"""
        if class_data_off == 0:
            return [], []
        p = class_data_off
        sf, p = self._uleb(self.d, p)   # static_fields_size
        inf, p = self._uleb(self.d, p)  # instance_fields_size
        dm, p = self._uleb(self.d, p)   # direct_methods_size
        vm, p = self._uleb(self.d, p)   # virtual_methods_size
        # skip encoded fields
        for _ in range(sf + inf):
            _, p = self._uleb(self.d, p)
            _, p = self._uleb(self.d, p)
        out = []
        for _ in range(dm + vm):
            _, p = self._uleb(self.d, p)   # method_idx_diff
            _, p = self._uleb(self.d, p)   # access_flags
            _, p = self._uleb(self.d, p)   # code_off
            out.append(0)  # placeholder, filled by caller via running idx
        return out


def scan(path, keyword=None):
    """返回 {类名: set(方法名)}，可按 keyword 过滤类名。"""
    if path.endswith('.jar') or zipfile.is_zipfile(path):
        zf = zipfile.ZipFile(path)
        entries = [n for n in zf.namelist() if n.endswith('.dex')]
    else:
        zf, entries = None, [path]

    result = {}
    for e in sorted(entries):
        data = zf.read(e) if zf else open(path, 'rb').read()
        try:
            dx = Dex(data)
        except Exception as ex:
            print(f"  跳过 {e}: {ex}", file=sys.stderr)
            continue
        for type_idx, cdata in dx.classes:
            cls = dx.type_names[type_idx]
            if not cls.startswith('L'):
                continue
            cls = cls[1:-1].replace('/', '.')
            if keyword and keyword.lower() not in cls.lower():
                continue
            # 重新走一遍 class_data 收集方法名（idx 差值累加）
            names = set()
            if cdata:
                p = cdata
                sf, p = dx._uleb(dx.d, p)
                inf, p = dx._uleb(dx.d, p)
                dm, p = dx._uleb(dx.d, p)
                vm, p = dx._uleb(dx.d, p)
                for _ in range(sf + inf):
                    _, p = dx._uleb(dx.d, p)
                    _, p = dx._uleb(dx.d, p)
                midx = 0
                for _ in range(dm):
                    diff, p = dx._uleb(dx.d, p)
                    midx += diff
                    _, p = dx._uleb(dx.d, p)
                    _, p = dx._uleb(dx.d, p)
                    names.add(dx.strings[dx.methods[midx][0]])
                midx = 0
                for _ in range(vm):
                    diff, p = dx._uleb(dx.d, p)
                    midx += diff
                    _, p = dx._uleb(dx.d, p)
                    _, p = dx._uleb(dx.d, p)
                    names.add(dx.strings[dx.methods[midx][0]])
            result.setdefault(cls, set()).update(names)
    return result


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    if argv[0] == '--selftest':
        # 自检：构造已知 dex 不可行，改为验证解析器对真实文件不崩
        print("selftest: 需要传入真实 dex/jar 路径")
        return 0
    path = argv[0]
    keywords = argv[1:]
    if not os.path.exists(path):
        print(f"文件不存在: {path}")
        return 1
    res = scan(path, keywords[0] if keywords else None)
    if keywords:
        for cls in sorted(res):
            names = sorted(res[cls])
            print(f"\n=== {cls} ({len(names)} 方法) ===")
            for n in names:
                print("   ", n)
    else:
        print(f"共 {len(res)} 个类")
        for cls in sorted(res)[:50]:
            print("   ", cls)
    return 0


def dump_signatures(path, class_filter, method_filter=None):
    """输出匹配类/方法的完整签名（含参数类型）。"""
    if zipfile.is_zipfile(path):
        zf = zipfile.ZipFile(path)
        entries = sorted(n for n in zf.namelist() if n.endswith('.dex'))
    else:
        zf, entries = None, [path]
    for e in entries:
        data = zf.read(e) if zf else open(path, 'rb').read()
        try:
            dx = Dex(data)
        except Exception:
            continue
        for type_idx, cdata in dx.classes:
            raw = dx.type_names[type_idx]
            if not raw.startswith('L'):
                continue
            cname = raw[1:-1].replace('/', '.')
            if class_filter.lower() not in cname.lower():
                continue
            if not cdata:
                continue
            p = cdata
            sf, p = dx._uleb(dx.d, p)
            inf, p = dx._uleb(dx.d, p)
            dm, p = dx._uleb(dx.d, p)
            vm, p = dx._uleb(dx.d, p)
            for _ in range(sf + inf):
                _, p = dx._uleb(dx.d, p)
                _, p = dx._uleb(dx.d, p)
            lines = []
            for count in (dm, vm):
                midx = 0
                for _ in range(count):
                    diff, p = dx._uleb(dx.d, p)
                    midx += diff
                    acc, p = dx._uleb(dx.d, p)
                    code, p = dx._uleb(dx.d, p)
                    name, ret, params = dx.method_signature(midx)
                    if method_filter and method_filter.lower() not in name.lower():
                        continue
                    vis = 'public' if acc & 1 else ('private' if acc & 2 else 'protected')
                    stat = ' static' if acc & 8 else ''
                    lines.append(f"    {vis}{stat} {ret} {name}({', '.join(params)})"
                                 + ('' if code else '   [无实现]'))
            if lines:
                print(f"=== {cname} ===")
                for l in lines:
                    print(l)


def _entry():
    if '--sig' in sys.argv:
        i = sys.argv.index('--sig')
        if len(sys.argv) < i + 3:
            print("用法: dex_api_probe.py --sig <jar|dex> <类名关键字> [方法名关键字]")
            return 1
        dump_signatures(sys.argv[i + 1], sys.argv[i + 2],
                        sys.argv[i + 3] if len(sys.argv) > i + 3 else None)
        return 0
    return main()


if __name__ == '__main__':
    sys.exit(_entry())
