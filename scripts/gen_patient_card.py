"""Rewrite reports/patient_card.tex: anatomy overlay in place of the box map."""
W, H = 513, 342
KEEP = 0.56          # keep the top 56% — all 21 pins are above y=160

# n, label, status, x_px, y_px, label_x, label_y   (status: crit|warn|safe|arte|unev)
PINS = [
    (1,  "Cerebral arterial",          "warn", 178,  30, 112,  16),
    (2,  "Intracranial CSF",           "crit", 189,  36, 112,  33),
    (3,  "Cerebral venous",            "unev", 200,  38, 252,  30),
    (4,  "Arteriolar bed",             "unev", 176,  43, 112,  50),
    (5,  "Capillary bed",              "unev", 186,  47, 252,  46),
    (6,  "Cerebral venous outflow",    "unev", 201,  28, 252,  14),
    (7,  "Craniospinal CSF channel",   "unev", 189,  54, 112,  67),
    (8,  "Sinus to jugular bulb",      "unev", 180,  57, 112,  84),
    (9,  "Jugular bulb",               "unev", 177,  61, 112, 101),
    (10, "Internal jugular",           "arte", 174,  67, 112, 118),
    (11, "Systemic venous",            "unev", 194,  95, None, None),
    (12, "Dural sinus",                "safe", 423,  14, None, None),
    (13, "CSF absorption, cranial",    "crit", 411,  21, None, None),
    (14, "Vertebral collateral",       "arte", 431,  55, None, None),
    (15, "Vertebral plexus",           "unev", 432, 104, None, None),
    (16, "Spinal dural sac",           "crit", 423, 113, None, None),
    (17, "Azygos return",              "unev", 409,  97, None, None),
    (18, "Paravertebral",              "unev", 411, 128, None, None),
    (19, "CSF absorption, spinal",     "crit", 423, 150, None, None),
    (20, "Plexus drainage",            "unev", 434, 134, None, None),
    (21, "Plexus shunt",               "unev", 441, 160, None, None),
]

TQ = [(0, 0, 134, 103), (230, 0, 366, 103)]

nx = lambda x: round(x / W, 5)
ny = lambda y: round(1 - y / (H * KEEP), 5)   # scope maps to the CROPPED node

pins, masks = [], []
for (x0, y0, x1, y1) in TQ:
    masks.append(f"    \\fill[white] ({nx(x0)},{ny(y1)}) rectangle ({nx(x1)},{ny(y0)});")
for (n, lab, st, x, y, lx, ly) in PINS:
    if lx is None:
        pins.append(f"    \\pin{st}{{{n}}}{{{nx(x)}}}{{{ny(y)}}}")
    else:
        pins.append(f"    \\lead{st}{{{n}}}{{{nx(x)}}}{{{ny(y)}}}{{{nx(lx)}}}{{{ny(ly)}}}")

# key, split into three columns by body region
ROWS = {
    "crit": "warning", "warn": "borderline", "safe": "within ref.",
    "arte": "artefact", "unev": "not evaluated",
}
key_lines = []
for (n, lab, st, *_r) in PINS:
    mark = {"crit": "\\textbf{w\\,1.53}" if "absorption" in lab else "\\textbf{w\\,0.63}",
            "warn": "w\\,0.39", "safe": "w\\,0.11",
            "arte": "\\textbf{NEEDS EVIDENCE}", "unev": "\\Q"}[st]
    if lab == "Intracranial CSF":
        mark = "\\textbf{w\\,0.63}"
    key_lines.append((n, lab, st, mark))

col = (len(key_lines) + 2) // 3
cols = [key_lines[i * col:(i + 1) * col] for i in range(3)]
keytex = []
for c in cols:
    body = " \\\\\n".join(
        f"    {{\\color{{c{st}}}$\\bullet$}}~{n} & {lab} & {mark}"
        for (n, lab, st, mark) in c)
    keytex.append("\\begin{tabular}{@{}r@{~}l l@{}}\n" + body + "\\\\\n\\end{tabular}")

TEX = r"""\documentclass[9pt,a4paper]{extarticle}
\usepackage[a4paper,top=1.1cm,bottom=1.0cm,left=1.2cm,right=1.2cm]{geometry}
\usepackage[T1]{fontenc}
\usepackage[utf8]{inputenc}
\usepackage{textcomp}
\usepackage{charter}
\usepackage[scaled=0.86]{helvet}
\usepackage{lmodern}
\usepackage{xcolor}
\usepackage{tikz}
\usepackage{graphicx}
\usepackage{booktabs}
\usepackage{array}
\usepackage{tabularx}
\usetikzlibrary{positioning,arrows.meta,shapes.geometric,backgrounds,fit}

\definecolor{ink}{HTML}{1B2A38}
\definecolor{faint}{HTML}{6E7B87}
\definecolor{rule}{HTML}{C3CCD4}

% Palette lifted from the patient-trend-pulse triage dashboard (src/index.css,
% "Medical Status Colors" / "Vital Sign Colors"), converted from HSL to hex.
\definecolor{ccrit}{HTML}{EF4343}   % --status-red      0 84% 60%
\definecolor{cwarn}{HTML}{E7B008}   % --status-yellow  45 93% 47%
\definecolor{csafe}{HTML}{16A249}   % --status-green  142 76% 36%
\definecolor{carte}{HTML}{F97415}   % --status-orange  25 95% 53%
\definecolor{cunev}{HTML}{94A3B8}   % --muted-foreground

\setlength{\parindent}{0pt}
\pagestyle{empty}

\newcommand{\hdr}[2][]{%
  {\sffamily\bfseries\footnotesize\color{ink}\MakeUppercase{#2}}%
  {\sffamily\footnotesize\color{faint}\,#1}%
  \par\vspace{1pt}{\color{rule}\hrule height .6pt}\vspace{3pt}}
% The patient's own words get a bigger header than the model's sections. On a card whose
% other content is machine output, the transcript is the only evidence that came from the
% patient, and it was previously the smallest thing on the page.
\newcommand{\hdrbig}[2][]{%
  {\sffamily\bfseries\large\color{ink}\MakeUppercase{#2}}%
  {\sffamily\small\color{faint}\,#1}%
  \par\vspace{2pt}{\color{rule}\hrule height .9pt}\vspace{5pt}}
\newcommand{\Q}{{\bfseries\normalsize ?}}

% --- anatomy pins. \pinXXXX puts the number on the point; \leadXXXX draws a leader.
\newcommand{\pinbase}[5]{\filldraw[#4,draw=white,line width=.5pt] (#2,#3) circle (1.85mm)
  node[#5,font=\bfseries\sffamily\fontsize{5}{5}\selectfont] {#1};}
\newcommand{\pincrit}[3]{\pinbase{#1}{#2}{#3}{ccrit}{white}}
\newcommand{\pinwarn}[3]{\pinbase{#1}{#2}{#3}{cwarn}{ink}}
\newcommand{\pinsafe}[3]{\pinbase{#1}{#2}{#3}{csafe}{white}}
\newcommand{\pinarte}[3]{\pinbase{#1}{#2}{#3}{carte}{white}}
\newcommand{\pinunev}[3]{\filldraw[white,draw=cunev,line width=.6pt] (#2,#3) circle (1.75mm)
  node[cunev,font=\bfseries\sffamily\fontsize{5}{5}\selectfont] {#1};}
\newcommand{\leadbase}[6]{\draw[#6,line width=.4pt] (#2,#3) -- (#4,#5);
  \filldraw[#6] (#2,#3) circle (0.45mm);}
\newcommand{\leadcrit}[5]{\leadbase{#1}{#2}{#3}{#4}{#5}{ccrit}\pincrit{#1}{#4}{#5}}
\newcommand{\leadwarn}[5]{\leadbase{#1}{#2}{#3}{#4}{#5}{cwarn}\pinwarn{#1}{#4}{#5}}
\newcommand{\leadsafe}[5]{\leadbase{#1}{#2}{#3}{#4}{#5}{csafe}\pinsafe{#1}{#4}{#5}}
\newcommand{\leadarte}[5]{\leadbase{#1}{#2}{#3}{#4}{#5}{carte}\pinarte{#1}{#4}{#5}}
\newcommand{\leadunev}[5]{\leadbase{#1}{#2}{#3}{#4}{#5}{cunev}\pinunev{#1}{#4}{#5}}

\begin{document}

%================================================================ header
{\sffamily\bfseries\large\color{ink} KOVALENKO, 34, M}\hfill
{\sffamily\small\color{faint} 2026-08-29 14:32 \;\textperiodcentered\; Stab.\ point \textit{Sokil}}\\[2pt]
{\color{ink}\hrule height 1pt}
\vspace{5pt}

%================================================================ vitals, full width
\hdrbig{Vitals}
\centering
\begin{tabular*}{\linewidth}{@{\extracolsep{\fill}}cccccccc@{}}
{\sffamily\small\color{faint}REPORT} &
{\sffamily\small\color{faint}BP} & {\sffamily\small\color{faint}HR} &
{\sffamily\small\color{faint}SpO$_2$} & {\sffamily\small\color{faint}RR} &
{\sffamily\small\color{faint}GCS} & {\sffamily\small\color{faint}TEMP} &
{\sffamily\small\color{faint}CAP REFILL}\\[5pt]
{\sffamily\bfseries\huge\color{ink}14:32} &
{\sffamily\bfseries\huge\color{ink}104/62} & {\sffamily\bfseries\huge\color{ink}118} &
{\sffamily\bfseries\huge\color{ink}94\%} & {\sffamily\bfseries\huge\color{ink}24} &
{\sffamily\bfseries\huge\color{ink}14} & {\sffamily\bfseries\huge\color{ink}36.4\,\textcelsius} &
{\sffamily\bfseries\huge\color{ink}3\,s}\\[4pt]
{\sffamily\small\color{faint}2026-08-29} & {\sffamily\small\color{faint}MAP 76} & & {\sffamily\small\color{faint}RA} & &
{\sffamily\small\color{faint}E4 V4 M6} & & \\
\end{tabular*}
\raggedright


\vspace{10pt}

%================================================================ transcript (first)
\hdrbig[--- verbatim, no clinician inference]{What the patient said}
\LARGE
\setlength{\extrarowheight}{9pt}
\begin{tabularx}{\linewidth}{@{}r l l X l@{}}
\toprule
\textbf{\#} & \textbf{Site} & \textbf{Time} & \textbf{Said} & \textbf{Requests}\\
\midrule
1 & POI            & 11:05 & ``head hurts, can't see right''    & water\\
2 & CCP            & 12:40 & neck pain turning left             & water $\times2$\\
3 & Stab.\ Sokil   & 14:20 & \textbf{headache worse lying flat} & asks about brother $\times2$\\
\bottomrule
\end{tabularx}
\setlength{\extrarowheight}{0pt}

\vspace{10pt}

\vspace{9pt}

%================================================================ title above the picture
{\sffamily\bfseries\huge\color{ink} PULSATILE ANALYSIS}\hfill
{\sffamily\footnotesize\color{faint} the CSF and venous circuit as 9 compartments and
12 interfaces \;\textperiodcentered\; colour = status, number = key below}\\[3pt]
{\color{ink}\hrule height 1.1pt}
\vspace{5pt}

\centering
\begin{tikzpicture}
  \node[anchor=south west,inner sep=0] (img)
    {\includegraphics[width=\textwidth]{../figures/body_template_upper.png}};
  \begin{scope}[x={(img.south east)},y={(img.north west)}]
__MASKS__
    \fill[white,opacity=0.5] (0,0) rectangle (1,1);
__PINS__
  \end{scope}
\end{tikzpicture}

\vspace{3pt}
{\footnotesize\color{ink}%
\tikz[baseline=-.5ex]\filldraw[ccrit] (0,0) circle (1.5mm); warning \quad
\tikz[baseline=-.5ex]\filldraw[cwarn] (0,0) circle (1.5mm); borderline \quad
\tikz[baseline=-.5ex]\filldraw[csafe] (0,0) circle (1.5mm); within ref. \quad
\tikz[baseline=-.5ex]\filldraw[carte] (0,0) circle (1.5mm); requires evidence \quad
\tikz[baseline=-.5ex]\filldraw[white,draw=cunev,line width=.6pt] (0,0) circle (1.4mm); \Q\ not evaluated\par}

\vspace{7pt}
{\sffamily\bfseries\Large\color{ink} The digital twin suggests investigating these zones.
\;{\color{ccrit}Not a diagnosis.}}\\[2pt]
{\sffamily\footnotesize\color{faint} Start with {\color{ccrit}\textbf{red}}. {\color{carte}\textbf{Orange}}
is the model correcting its own arithmetic --- not a finding in this patient. Grey was not
measured at all.}

\vspace{8pt}
\raggedright
\hdrbig{Component key}
{\normalsize
__KEY0__ \hfill
__KEY1__ \hfill
__KEY2__
\par}
\vspace{3pt}
{\footnotesize\color{ink}\textbf{w} = how far outside the normal band, 1.0 = at the danger
bound. \textbf{13 of 21 parts show \Q\ --- not measured, which is not the same as normal.}
The two {\color{carte}\textbf{requires-evidence}} parts are the model correcting its own arithmetic and
are \textbf{not statements about this patient}.\par}

\vspace{6pt}
{\color{rule}\hrule height .6pt}
\vspace{3pt}
{\footnotesize\color{faint}Component weights and the artefact call are real output for recording
081. \textbf{Name, age, sex, vitals and transcript are synthetic.} Not a diagnosis --- confirm
before acting.\par}

\end{document}
"""

TEX = (TEX.replace("__MASKS__", "\n".join(masks))
          .replace("__PINS__", "\n".join(pins))
          .replace("__KEY0__", keytex[0])
          .replace("__KEY1__", keytex[1])
          .replace("__KEY2__", keytex[2]))

out = "/home/thermistor/Documents/icp-parameter-api/reports/patient_card.tex"
with open(out, "w") as f:
    f.write(TEX)
print("wrote", out)
print(f"{len(PINS)} pins;", {s: sum(1 for p in PINS if p[2] == s) for s in ROWS})
