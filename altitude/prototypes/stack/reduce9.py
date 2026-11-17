"""Reduce an Altitude export to the data the layer-stack prototype needs and inline it.

Usage: python3 -I reduce.py <export dir> <template.html> <out.html>
"""
import json, sys

src, template, out = sys.argv[1:4]
d = json.load(open(src + '/altitude.json'))
# Every file of one export carries the same exportId; refuse to mix runs.
ids = {}
for f in ['altitude.json', 'altitude-nodes.json', 'altitude-members.json', 'altitude-variables.json', 'altitude-branches.json', 'altitude-branch-sinks.json']:
    ids[f] = json.load(open(src + '/' + f))['meta']['exportId']
if len(set(ids.values())) != 1:
    sys.exit('exportId mismatch: ' + json.dumps(ids))
EXPORT_ID = d['meta']['exportId']
print('exportId', EXPORT_ID, 'agrees across', len(ids), 'files')
try:
    detail = json.load(open(src + '/altitude-nodes.json'))['nodes']
except FileNotFoundError:
    detail = {}

containers = {c['id']: c for c in d['containers']}
feat_ids = [f['id'] for f in d['features']]
feat_index = {f: i for i, f in enumerate(feat_ids)}
features = []
for f in d['features']:
    features.append({
        'id': f['id'], 'module': f['module'], 'pkg': f['pkg'],
        'loc': f['size']['loc'], 'nodes': f['size'].get('nodes', 0), 'entry': f.get('entrypoints', 0),
    })

nodes = d['nodes']
node_index = {n['id']: i for i, n in enumerate(nodes)}


def chain(container_id):
    out = []
    cur = containers.get(container_id)
    while cur:
        out.append(cur)
        cur = containers.get(cur.get('parent'))
    return list(reversed(out))


# The containment relation as the export has it: kinds ordered by their shallowest depth, then a flat
# table of [kind index, name, qualified, parent index], and each node's own container index.
kind_depth = {}
for c in d['containers']:
    kind_depth[c['kind']] = min(kind_depth.get(c['kind'], 99), c['depth'])
container_kinds = sorted(kind_depth, key=lambda k: (kind_depth[k], k))
ckind_index = {k: i for i, k in enumerate(container_kinds)}
cont_ids = [c['id'] for c in d['containers']]
cont_index = {cid: i for i, cid in enumerate(cont_ids)}
cont_table = [[ckind_index[c['kind']], c['name'], c['qualified'], cont_index.get(c.get('parent'), -1)] for c in d['containers']]

# Files by path, so a node names its file once. A node's line range runs from its own line to its last member's.
file_paths = sorted({n['file'] for n in nodes})
file_index = {f: i for i, f in enumerate(file_paths)}
try:
    _mem = json.load(open(src + '/altitude-members.json'))
except FileNotFoundError:
    _mem = {'members': []}
last_line = {}
for x in _mem['members']:
    if x.get('l'): last_line[x['n']] = max(last_line.get(x['n'], 0), x['l'][-1])
out_nodes = []
for n in nodes:
    ch = chain(n['container'])
    module = next((c['name'] for c in ch if c['kind'] == 'module'), '?')
    ss = next((c['name'] for c in ch if c['kind'] == 'sourceSet'), '?')
    pkgs = [c['qualified'] for c in ch if c['kind'] == 'package']
    det = detail.get(n['id'], {})
    fan = det.get('fanIn', {})
    reach = det.get('reach', {})
    inf = n.get('infrastructure', {})
    rec = {
        'n': n['name'], 'k': n['kind'], 'f': feat_index.get(n.get('feature'), -1),
        'm': module, 'ss': ss, 'p': pkgs[-1] if pkgs else '', 'file': n['file'].split('/')[-1],
        'c': cont_index.get(n['container'], -1),
        'L': n.get('layer', -1), 'w': n.get('layerWhy', ''),
        's': n['size'].get('loc', 0), 'dc': n['size'].get('decls', 0),
    }
    rec['fp'] = file_index[n['file']]
    if n.get('line'):
        rec['ln'] = n['line']
        end = last_line.get(len(out_nodes), 0)
        if end > n['line']: rec['le'] = end
    if n.get('generated'): rec['gen'] = 1
    if n.get('staged'): rec['st'] = 1
    if n.get('nonProduction'): rec['np'] = n['nonProduction']
    if inf.get('flag'): rec['inf'] = 1
    if inf.get('score'): rec['sc'] = inf['score']
    if inf.get('why'): rec['iw'] = inf['why']
    roles = [r['role'] for r in n.get('roles', [])]
    if roles: rec['r'] = roles
    if fan.get('nodes'): rec['fi'] = [fan['nodes'], len(fan.get('features', [])), fan.get('layers', [])]
    if reach.get('entries'): rec['re'] = [len(reach['entries']), len(reach.get('byContainer', {}).get('feature', []))]
    if det.get('misplaced'): rec['mis'] = 1
    # Layer evidence: the layers it has code on, scores, flow vote, hints, neighbour placement and conflict.
    if len(n.get('layers', [])) > 1: rec['lys'] = n['layers']; rec['lsz'] = n.get('layerSizes', {})
    if det.get('layerScores'): rec['lsc'] = det['layerScores']
    if det.get('layerFlowVote') is not None: rec['lfv'] = det['layerFlowVote']
    if det.get('layerHints'): rec['lh'] = det['layerHints']
    if det.get('layerInferred'): rec['li'] = det['layerInferred']; rec['lnb'] = det.get('layerNeighbours', {})
    if det.get('layerConflict'): rec['lc'] = 1
    out_nodes.append(rec)

kinds = sorted({e['kind'] for e in d['edges']})
kind_index = {k: i for i, k in enumerate(kinds)}
edges = [[node_index[e['from']], node_index[e['to']], kind_index[e['kind']], e['count']] for e in d['edges']]

def holder(h):
    # 'path/File.kt:121:5-128:8:local' becomes 'File.kt:121 local'
    parts = h.split(':')
    if len(parts) < 3: return h
    return parts[0].split('/')[-1] + ':' + parts[1] + ' ' + parts[-1]
import re
_cell_root = {}
for _t in json.load(open(src + '/altitude-branches.json'))['trees']:
    _r = _t['root']
    if _r['kind'] == 'cell' and _r.get('label'): _cell_root.setdefault(_r['ref'], _r['label'])
# A cell's short label: the mechanism's last word, then the holder's name and site, as `stateIn @File.kt:97`.
def cell_label(ci, c):
    mech = c.get('mechanism', '') or ''
    word = mech.split(' ')[-1] if mech else 'cell'
    lab = _cell_root.get(ci)
    if lab and lab.startswith(mech + ' '):
        rest = lab[len(mech) + 1:]
    else:
        h = c.get('holder', '') or ''
        rest = h.split('/')[-1] if h.startswith('prop:') else '@' + c['id'].split('/')[-1]
    if rest.startswith('callResult@'): rest = rest[len('callResult'):]
    rest = re.sub(r'@([^:@]+:\d+):\d+(-\S*)?$', r'@\1', rest)
    rest = re.sub(r'@([^:@]+:\d+):\d+:\d+-\d+:\d+:\w+$', r'@\1', rest)
    return word + ' ' + rest
cells = []
for ci, c in enumerate(d['cells']):
    cells.append({'l': cell_label(ci, c),
        'o': node_index.get(c['owner'], -1), 'm': c.get('mechanism', ''), 'sc': c.get('scope', ''),
        'n': c['id'].split(':')[-1], 'h': holder(c.get('holder', '')),
        'w': sorted({node_index[x['node']] for x in c.get('writers', []) if x['node'] in node_index}),
        'r': sorted({node_index[x['node']] for x in c.get('readers', []) if x['node'] in node_index}),
    })

# Members, reordered by id within each node so the page packs them in a stable order. One row per member:
# [node, kind, sig, size, lambdas, flag bits, cell index or -1, parent member or -1, name when sig does not start with it, staged].
try:
    mem = json.load(open(src + '/altitude-members.json'))
except FileNotFoundError:
    mem = {'members': [], 'edges': []}
MKINDS = ['function', 'constructor', 'initializer', 'property', 'cell']
MFLAGS = ['composable', 'suspend', 'override', 'generated', 'get', 'set', 'enumEntry', 'ctorParam', 'abstract', 'delegated', 'var', 'implicit']
src_members = mem['members']
order = sorted(range(len(src_members)), key=lambda i: (src_members[i]['n'], src_members[i]['id']))
new_index = {old: new for new, old in enumerate(order)}
member_id_index = {src_members[old]['id']: new for new, old in enumerate(order)}
members = []
for old in order:
    x = src_members[old]
    bits = 0
    for b, f in enumerate(MFLAGS):
        if f in x.get('fl', []): bits |= 1 << b
    sig = x.get('sig', x['name'])
    row = [x['n'], MKINDS.index(x['k']), sig, x.get('s', 0), x.get('lam', 0), bits,
           (x.get('cell') or [-1])[0], new_index[x['p']] if isinstance(x.get('p'), int) else member_id_index.get(x.get('p'), -1)]
    tail = [x['name'] if not sig.startswith(x['name']) else 0, x.get('np', 0)]
    while tail and not tail[-1]: tail.pop()
    members.append(row + tail)
member_lines = []
for old in order:
    l = src_members[old].get('l') or [0, 0]
    member_lines += [l[0], l[-1] - l[0]]
medges = []
for e in sorted(mem['edges'], key=lambda e: (new_index[e['a']], new_index[e['b']], e['k'])):
    medges += [new_index[e['a']], new_index[e['b']], kind_index[e['k']], e['c']]

traces = []
for t in d['traces']:
    legs = []
    for leg in t['legs']:
        # Per hop: from member, to member (-1 for a library end), the cell the hop joins or writes (-1), and for a
        # field mismatch the text naming it (the property read, and the field the innermost partOf built it in as).
        hops, built = [], []
        for h in leg.get('hops', []):
            row = [member_id_index.get(h.get('fromMember'), -1), member_id_index.get(h.get('toMember'), -1),
                   h['cell'] if isinstance(h.get('cell'), int) else -1]
            if h.get('kind') == 'partOf' and h.get('field'): built.append(h['field'])
            if h.get('fieldMismatch'):
                row.append('field mismatch: reads ' + str(h.get('property') or '?') + (', built in as ' + built[-1] if built else ''))
            elif h.get('kind') == 'memberOf' and built: built.pop()
            hops.append(row)
        legs.append({'from': leg['from'], 'to': leg['to'], 'path': [node_index[x] for x in leg['nodePath'] if x in node_index], 'hops': hops})
    traces.append({'name': t['name'], 'kind': t['kind'], 'comment': t.get('comment', ''), 'query': t.get('query', ''),
                   'matches': bool(t.get('matchesGolden')), 'legs': legs})

# Branch trees, shrunk: no hop table and no locations. Trees with no terminal are dropped.
# A tree: r = [root kind, dir (0 forward, 1 backward), ref (-1 when none), point index of the root, label],
# p = flat [kind, member, node] per point, s = [a, b, hopCount, approx bits, cost, members] per segment,
# t = [point, kind, ref, equalCostPaths, clean, cost, segments or 0 when the chain of first segments gives them],
# x = [at, kind (0 join, 1 split), [[member, name], ...]]. A cost is [anyInstanceReads, stagedHops, conflation,
# derivedHops, length] with trailing zeros dropped.
RKINDS = ['cell', 'boundary', 'traceEnd']
PKINDS = ['root', 'branch', 'merge', 'join', 'split', 'terminal']
TKINDS = ['boundary', 'cellWrite', 'cellRead', 'ui', 'entry', 'sink']
APPROX = ['anyInstance', 'anyContainer', 'fieldMismatch', 'staged', 'unmatchedReturn']
COST = ['anyInstanceReads', 'stagedHops', 'conflation', 'derivedHops', 'length']
def cost(c):
    out = [c.get(k, 0) for k in COST]
    while out and not out[-1]: out.pop()
    return out
mem_new = lambda m: new_index[m] if isinstance(m, int) and m in new_index else -1
br = json.load(open(src + '/altitude-branches.json'))
var_src = json.load(open(src + '/altitude-variables.json'))
var_index = {x['id']: i for i, x in enumerate(var_src['vars'])}

# Strings the page shows for hops and links, each once.
strs, str_ix = [], {}
def S(x):
    if x not in str_ix: str_ix[x] = len(strs); strs.append(x)
    return str_ix[x]
S('')
bs = br['strs']
src_files = d['files']
def site(s):
    f, l = s.split(':')
    return S(src_files[int(f)].split('/')[-1] + ':' + l)
# A hop: [kind, site, fromMember, toMember, fromVar, toVar, approx bits (export x), note]. The note joins the
# property read, the field built in, the landmark and the any-instance property.
hops = []
for h in br['hops']:
    note = []
    if 'p' in h: note.append('reads ' + bs[h['p']])
    if 'fd' in h: note.append('built in as ' + bs[h['fd']])
    if 'ai' in h: note.append('any instance of ' + bs[h['ai']])
    if 'lm' in h: note.append(bs[h['lm']])
    hops.append([S(bs[h['k']]), site(h['s']), mem_new(h.get('fm')), mem_new(h.get('tm')), h.get('fv', -1), h.get('tv', -1), h.get('x', 0), S('; '.join(note))])

tree_new = {}
for i, t in enumerate(br['trees']):
    if t['terminals']: tree_new[i] = len(tree_new)
trees = []
dropped_empty = 0
for t in br['trees']:
    if not t['terminals']:
        dropped_empty += 1
        continue
    pts, sk = [], []
    for k, p in enumerate(t['points']):
        pts += [PKINDS.index(p['kind']), mem_new(p.get('member')), p.get('node', -1)]
        if p.get('sk'): sk += [k, p['sk']]
    segs = []
    for s in t['segments']:
        bits = 0
        for i, a in enumerate(APPROX):
            if a in s.get('approx', []): bits |= 1 << i
        segs.append([s['a'], s['b'], s['hopCount'], bits, cost(s.get('cost', {})), [mem_new(m) for m in s['members']], s.get('hops', 0)])
    # A chain is in data-flow order: root to terminal forward, terminal to root backward. Its default is the chain of
    # first segments toward the root.
    back = t['root']['dir'] != 'forward'
    near, far = ('a', 'b') if back else ('b', 'a')
    par = {}
    for i, s in enumerate(t['segments']): par.setdefault(s[near], i)
    terms = []
    for x in t['terminals']:
        ch, p, seen = [], x['point'], set()
        while p in par and p not in seen: seen.add(p); ch.append(par[p]); p = t['segments'][par[p]][far]
        if not back: ch.reverse()
        ref = x.get('ref', -1)
        if x['kind'] in ('ui', 'sink'): ref = mem_new(ref)
        at = -1
        if 'at' in x: at = var_index.get(br['locs'][x['at']], -1)
        row = [x['point'], TKINDS.index(x['kind']), ref, x.get('equalCostPaths', 1), 1 if x['clean'] else 0, cost(x.get('cost', {})),
               0 if ch == x['segments'] else x['segments']]
        if at >= 0: row.append(at)
        terms.append(row)
    sibs = [[s['at'], 0 if s['kind'] == 'join' else 1, [[mem_new(v.get('member')), v.get('name', '')] for v in s['values']]] for s in t.get('siblings', [])]
    r = t['root']
    root_pt = next(i for i, p in enumerate(t['points']) if p['kind'] == 'root')
    rec = {'r': [RKINDS.index(r['kind']), 0 if r['dir'] == 'forward' else 1, r.get('ref', -1), root_pt, r.get('label', '')],
           'p': pts, 's': segs, 't': terms, 'x': sibs}
    if sk: rec['sk'] = sk
    trees.append(rec)

# Cell links: per cell, the writer chains, the reader chains of the trees rooted at it, the access paths and, per
# writer, one compat character per reader (m match, x mismatch, u unknown). rd: backward chains ending in a read.
def path_s(p):
    if not p: return '(whole contents)'
    s = ''
    for x in p: s += x if x == '[]' else ('.' if s else '') + x
    return s
tk = lambda pair: [tree_new[pair[0]], pair[1]] if pair[0] in tree_new else None
links = []
for l in br['links']:
    w = [tk(p) for p in l.get('w', [])]; rc = [tk(p) for p in l.get('rc', [])]; rd = [tk(p) for p in l.get('rd', [])]
    links.append({'c': l['cell'], 'w': w, 'rc': rc, 'rd': [x for x in rd if x], 'wa': [S(path_s(p)) for p in l.get('wa', [])],
                  'ra': [S(path_s(p)) for p in l.get('ra', [])], 'cp': l.get('compat', []), 'i': 1 if l.get('instance') == 'any' else 0})

# Variables: [member, kind, name, line, lambda (-1), rank, flags (1 by, 2 remember), label (0), type (0), captured by n lambdas].
VKINDS = ['param', 'receiver', 'local', 'lambdaParam', 'temp']
VRANKS = ['other', 'stateRead', 'output', 'eventCapture']
vars_out = []
for x in var_src['vars']:
    fl = (1 if x.get('dl') else 0) | (2 if x.get('rem') else 0)
    vars_out.append([mem_new(x['m']), VKINDS.index(x['k']), x['n'], x.get('l', 0), x.get('lam', -1), VRANKS.index(x.get('rank', 'other')), fl,
                     x.get('lbl', 0), x.get('t', 0), len(x.get('cap', []))])
lambdas = [[mem_new(x['m']), x.get('o', 0), (x.get('l') or [0, 0])[0], (x.get('l') or [0, 0])[-1], x.get('p', -1), 1 if x.get('cmp') else 0] for x in var_src['lambdas']]
member_ly = [src_members[old].get('ly', -1) for old in order]
boundaries = [[f"{b.get('system', '')}:{b.get('kind', '')} {b.get('op', '')}", node_index.get(b.get('node'), -1)] for b in d.get('boundaries', [])]
entrypoints = [[e.get('kind', ''), e.get('sym', '').split('/')[-1], node_index.get(e.get('node'), -1)] for e in d.get('entrypoints', [])]
bindings = [[b.get('type', '').split('.')[-1], b.get('kind', ''), node_index.get(b.get('providerNode'), -1), node_index.get(b.get('graphNode'), -1), b.get('variant', '')]
            for b in d.get('bindings', [])]
print('branch trees kept', len(trees), 'dropped with no terminal', dropped_empty, 'of', len(br['trees']), 'explicit chains', sum(1 for t in trees for x in t['t'] if x[6]))

data = {
    'meta': {'target': d['meta']['target'], 'gitSha': d['meta']['gitSha'], 'layers': d['meta']['layers'],
             'counts': d['meta']['counts'], 'params': d['meta']['params'], 'exportId': EXPORT_ID},
    'features': features, 'containerKinds': container_kinds, 'containers': cont_table, 'nodes': out_nodes, 'edgeKinds': kinds, 'edges': edges,
    'cells': cells, 'traces': traces,
    'memberKinds': MKINDS, 'memberFlags': MFLAGS, 'members': members, 'memberEdges': medges,
    'branches': {'rootKinds': RKINDS, 'pointKinds': PKINDS, 'termKinds': TKINDS, 'approx': APPROX, 'cost': COST, 'trees': trees, 'hops': hops, 'links': links, 'hopDetailDropped': br['counts'].get('hopDetailDropped', 0)},
    'strs': strs, 'varKinds': VKINDS, 'varRanks': VRANKS, 'vars': vars_out, 'lambdas': lambdas, 'memberLayers': member_ly,
    'boundaries': boundaries, 'entrypoints': entrypoints, 'bindings': bindings, 'files': file_paths, 'memberLines': member_lines,
}
blob = json.dumps(data, separators=(',', ':'), sort_keys=True).replace('</', '<\\/')
html = open(template).read()
marker = '/*__DATA__*/null'
assert marker in html
open(out, 'w').write(html.replace(marker, blob))
print('data bytes', len(blob), 'html bytes', len(html) + len(blob) - len(marker))
