#!/usr/bin/env python3
"""One-page report of a pudding boot log.

  run_report.py out/ioslog-NAME.txt

Prints: log header, exec timeline after boot settled, crashes per process with the first
and last time, framebuffer presents (and when the last one was), the display power events,
HFS inconsistency lines, and the screen timeline from the kernel thumbnails (0250) with a
change marker, so a run can be skimmed in a few seconds.
"""
import hashlib
import re
import sys

T = re.compile(r'^\[\s*([0-9.]+)\]')
THUMB = re.compile(r'SWEET THUMB (\S+) (\d+) ([0-9a-f]{10,})')
EXEC = re.compile(r'\] exec (\S+)$')


def main():
    path = sys.argv[1]
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    head = lines[0] if lines and lines[0].startswith('#') else ''
    print(head)
    execs, crashes, presents, screens = [], {}, [], {}
    display = []
    hfs = 0
    for line in lines:
        m = T.match(line)
        if not m:
            continue
        t = float(m.group(1))
        e = EXEC.search(line)
        if e:
            execs.append((t, e.group(1)))
        if ' CRASH ' in line:
            who = line.split('CRASH ', 1)[1].split('[')[0].strip()
            crashes.setdefault(who, []).append(t)
        if 'SWEET FB: swap ' in line and 'layer' in line:
            presents.append(t)
        if 'SWEET FB: display on' in line and 'display off' not in line:
            display.append((t, 'on'))
        if 'SWEET FB: display off' in line:
            display.append((t, 'off'))
        if 'Runtime corruption' in line:
            hfs += 1
        m2 = THUMB.search(line)
        if m2:
            screens.setdefault(m2.group(1), {})[int(m2.group(2))] = m2.group(3)

    print(f'log lines {len(lines)}, hfs inconsistency lines {hfs}')
    print(f'display: {display[:4]}{" ..." if len(display) > 4 else ""}')
    if presents:
        print(f'presents: {len(presents)}, first {presents[0]:.1f}s, last {presents[-1]:.1f}s')
    else:
        print('presents: none')

    late = [(t, n) for t, n in execs if t > 600 and n not in ('xpcproxy', 'bluetoothd', 'fairplayd.H2')]
    print(f'non-noise execs after 600 s: {len(late)}')
    if late:
        buckets = {}
        for t, n in late:
            buckets.setdefault(int(t) // 100 * 100, []).append(n)
        for b in sorted(buckets)[:8]:
            print(f'  {b:4d}-{b+99:4d}s: {len(buckets[b]):3d}  ' + ' '.join(buckets[b][:6]))

    if crashes:
        print('crashes:')
        for who, ts in sorted(crashes.items(), key=lambda kv: -len(kv[1]))[:6]:
            print(f'  {who:20s} {len(ts):4d}  {ts[0]:.0f}s .. {ts[-1]:.0f}s')

    if screens:
        print('screen timeline:')
        prev = None
        for tag in sorted(screens, key=lambda x: int(x) if x.isdigit() else 1 << 30):
            blob = ''.join(screens[tag][y] for y in sorted(screens[tag]))
            h = hashlib.sha256(blob.encode()).hexdigest()[:8]
            bright = sum(1 for c in blob if c in '89abcdef')
            mark = ''
            if prev is not None and h != prev:
                mark = ' changed'
            prev = h
            print(f'  {tag:>6} {h} bright={bright:4d}{mark}')


main()
