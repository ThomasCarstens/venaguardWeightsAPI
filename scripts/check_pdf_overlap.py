import re, sys, subprocess, itertools
pdf=sys.argv[1]
thr=float(sys.argv[2]) if len(sys.argv)>2 else 0.05
xml=subprocess.run(["pdftotext","-bbox",pdf,"-"],capture_output=True,text=True).stdout
pw=float(re.search(r'width="([\d.]+)"',xml).group(1)); ph=float(re.search(r'height="([\d.]+)"',xml).group(1))
W=[]
for m in re.finditer(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>',xml):
    W.append(tuple(map(float,m.groups()[:4]))+(m.group(5),))
print(f"page {pw:.0f}x{ph:.0f}pt, {len(W)} words")
# margins: geometry says left/right 1.2cm = 34pt
L,R,T,B = 34,pw-34,31,ph-28
out=[w for w in W if w[0]<L-1 or w[2]>R+1 or w[1]<T-1 or w[3]>B+1]
print(f"outside margins: {len(out)}")
for w in out[:8]: print(f"   x[{w[0]:.0f},{w[2]:.0f}] y[{w[1]:.0f},{w[3]:.0f}]  {w[4]!r}")
def ov(a,b):
    dx=min(a[2],b[2])-max(a[0],b[0]); dy=min(a[3],b[3])-max(a[1],b[1])
    return dx*dy if dx>0 and dy>0 else 0.0
bad=[]
for a,b in itertools.combinations(W,2):
    o=ov(a,b)
    if o<=0: continue
    sa=(a[2]-a[0])*(a[3]-a[1]); sb=(b[2]-b[0])*(b[3]-b[1])
    f=o/min(sa,sb) if min(sa,sb)>0 else 0
    if f>thr: bad.append((f,a,b))
bad.sort(reverse=True,key=lambda r:r[0])
print(f"overlaps >{thr*100:.0f}%: {len(bad)}")
for f,a,b in bad[:20]:
    print(f"   {f*100:5.1f}%  y={a[1]:6.1f}  {a[4]!r:30} <-> {b[4]!r}")
# horizontally adjacent pairs on the same line with < 0.5pt gap (reads as collision)
same=[]
for a,b in itertools.combinations(W,2):
    if abs(a[1]-b[1])>2: continue
    lo,hi=(a,b) if a[0]<b[0] else (b,a)
    gap=hi[0]-lo[2]
    if -0.5<gap<0.4: same.append((gap,lo,hi))
same.sort(key=lambda r:r[0])
print(f"same-line gaps < 0.4pt: {len(same)}")
for g,a,b in same[:12]:
    print(f"   gap={g:5.2f}pt y={a[1]:6.1f}  {a[4]!r:26} | {b[4]!r}")
