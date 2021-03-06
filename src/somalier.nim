{.experimental.}

import ./cluster
import os
import hts
import math
import json
import ./parseopt3
import algorithm
import ospaths
import strutils
import threadpool
import ./results_html


type Site* = object
  ref_allele: char
  chrom: string
  position: int

type count* = object
  nref: int
  nalt: int

proc ab*(c:count): float {.inline.} =
  return c.nalt.float / (c.nalt + c.nref).float

proc alts*(c:count, min_depth:int): int8 {.inline.} =
  ## give an estimate of number of alts from counts of ref and alt
  ## AB < 0.15 is called as hom-ref
  ## AB > 0.75 is hom-alt
  ## 0.15 <= AB <= 0.75 is het
  if c.nref + c.nalt < min_depth:
    return -1
  if c.nalt == 0:
    return 0

  var ab = c.ab

  if ab < 0.07:
    return 0
  if ab > 0.88:
    return 2

  if ab < 0.2 or ab > 0.8: return -1 # exclude mid-range hets.

  return 1

proc count_alleles(b:Bam, site:Site): count =
  for aln in b.query(site.chrom, site.position, site.position + 1):
    var off = aln.start
    var qoff = 0
    var roff_only = 0
    for event in aln.cigar:
      var cons = event.consumes
      if cons.query:
        qoff += event.len
      if cons.reference:
        off += event.len
        if not cons.query:
          roff_only += event.len
      if off <= site.position: continue

      var over = off - site.position - roff_only
      var base = aln.base_at(qoff - over)
      if base == site.ref_allele:
        result.nref += 1
      else:
        result.nalt += 1

proc writeHelp() =
  stderr.write """
somalier rel [options] <bam/cram>...

Arguments:
  <bam/cram> file(s) for samples of interest.

Options:

  -s --sites <vcf>        vcf file with lines of sites to use for relatedness estimation.
  -t --threads <int>      optional number of processors to use for parallelization.
  -f --fasta <reference>  path to reference fasta file.
  -g --groups <path>      optional path to expected groups of samples (e.g. tumor normal pairs).
                          specified as comma-separated groups per line e.g.:
                            normal1,tumor1a,tumor1b
                            normal2,tumor2a
  -o --output <prefix>    output prefix for results.

  """

proc get_bam_alts(bams:seq[BAM], site:Site, nalts: var seq[int8], min_depth:int=6, report:bool=true): int =
  ## returns number of known genotypes
  if bams.len == 0:
    return 0

  var nref = 0
  var nalt = 0

  for bam in bams:
    var c = bam.count_alleles(site)
    var calts = c.alts(min_depth)
    if calts != -1:
      result += 1
    if c.nref > 0:
      nref = 1
    if c.nalt > 0:
      nalt = 1
    nalts.add(calts)
  if nref == 0:
    if report:
      stderr.write_line "[somalier] no reference alleles found at: ", $site
    return -1
  if nalt == 0:
    if report:
      stderr.write_line "[somalier] no alternate alleles found at: ", $site
    return -1


proc get_depths(v:Variant, cache: var seq[int32]): seq[int32] =
  for c in cache.mitems:
    c = 0
  if v.format.ints("AD", cache) == Status.OK:
    result = newSeq[int32](v.n_samples)
    for i in 0..<v.n_samples:
      result[i] = cache[2*i] + cache[2*i+1]
    return

  if v.format.ints("DP", cache) == Status.OK:
    result = newSeq[int32](v.n_samples)
    copyMem(result[0].addr, cache[0].addr, sizeof(cache[0]) * cache.len)
    return 

  return nil


proc get_vcf_alts(vcfs:seq[VCF], site:Site, nalts: var seq[int8], cache: var seq[int32], min_depth:int): int =
  if len(vcfs) == 0:
    return 0

  var n:int

  for vcf in vcfs:
    var found = 0
    n += vcf.n_samples
    {.gcsafe.}:
      for v in vcf.query(site.chrom & ":" & $(site.position + 1) & "-" & $(site.position + 2)):
        if v.REF[0] != site.ref_allele: continue
        var alts = v.format.genotypes(cache).alts
        var dps = get_depths(v, cache)
        for k, alt in alts.mpairs:
          if dps != nil and dps[k] < min_depth:
            alt = -1
          if alt != -1:
            found += 1
        nalts.add(alts)

    result += found


proc krelated(alts: var seq[int8], ibs: var seq[uint16], n: var seq[uint16], hets: var seq[uint16], homs: var seq[uint16], shared_hom_alts: var seq[uint16], n_samples: int): int =

  if alts[n_samples - 1] == 1:
    hets[n_samples-1] += 1
  elif alts[n_samples - 1] == 2:
    homs[n_samples-1] += 1

  var is_het: bool
  var aj, ak: int8
  var nused = 0

  for j in 0..<(n_samples-1):
    aj = alts[j]
    if aj == -1: continue
    is_het = (aj == 1)

    if is_het:
      hets[j] += 1
    elif aj == 2:
      homs[j] += 1

    nused += 1

    for k in j+1..<n_samples:
      ak = alts[k]
      if ak == -1: continue
      n[j * n_samples + k] += 1
      if is_het:
        # shared hets
        if ak == 1:
          ibs[k * n_samples + j] += 1
      else:
        # ibs0
        if aj != ak and aj + ak == 2:
          ibs[j * n_samples + k] += 1
      # ibs2
      if aj == ak: #and not is_het:
        n[k * n_samples + j] += 1
        if aj == 2:
          shared_hom_alts[j * n_samples + k] += 1
  return nused

type relation = object
  sample_a: string
  sample_b: string
  hets_a: uint16
  hets_b: uint16
  hom_alts_a: uint16
  hom_alts_b: uint16
  shared_hom_alts: uint16
  shared_hets: uint16
  ibs0: uint16
  ibs2: uint16
  n: uint16

proc hom_alt_concordance(r: relation): float64 {.inline.} =
  return (r.shared_hom_alts.float64 - 2 * r.ibs0.float64) / min(r.hom_alts_a, r.hom_alts_b).float64

proc rel(r:relation): float64 {.inline.} =
  return (r.shared_hets.float64 - 2 * r.ibs0.float64) / min(r.hets_a, r.hets_b).float64

const header = "$sample_a\t$sample_b\t$relatedness\t$hom_concordance\t$hets_a\t$hets_b\t$shared_hets\t$hom_alts_a\t$hom_alts_b\t$shared_hom_alts\t$ibs0\t$ibs2\t$n"
proc `$`(r:relation): string =
  return header % [
         "sample_a", r.sample_a, "sample_b", r.sample_b,
         "relatedness", formatFloat(r.rel, ffDecimal, precision=3),
         "hom_concordance", formatFloat(r.hom_alt_concordance, ffDecimal, precision=3),
         "hets_a", $r.hets_a, "hets_b", $r.hets_b,
         "shared_hets", $r.shared_hets, "hom_alts_a", $r.hom_alts_a, "hom_alts_b", $r.hom_alts_b, "shared_hom_alts", $r.shared_hom_alts, "ibs0", $r.ibs0, "ibs2", $r.ibs2, "n", $r.n]

type relation_matrices = object
   sites_tested: int
   ibs: seq[uint16]
   n: seq[uint16]
   hets: seq[uint16]
   homs: seq[uint16]
   shared_hom_alts: seq[uint16]
   samples: seq[string]
   clusters: seq[seq[string]]

proc n_samples(r: relation_matrices): int {.inline.} =
  return r.samples.len

proc bam_like(path:string): bool {.inline.} =
    return path.endsWith(".bam") or path.endsWith(".cram")

proc relmatrix(paths:seq[string], sites:seq[Site], p: ptr relation_matrices, idx:int): bool {.thread.} =
  result = true

  var bams = newSeqOfCap[Bam](len(paths))
  var vcfs = newSeqOfCap[VCF](2)
  for i, path in paths:
    if path.bam_like:
      var b:Bam
      open(b, path, index=true)
      bams.add(b)
    else:
      var vcf: VCF
      if not open(vcf, path):
        quit "could not open " & $path
      vcfs.add(vcf)

  var nalts = newSeqOfCap[int8](16)
  var rel = p[]

  if rel.hets == nil:
    stderr.write_line "skipped:", len(sites), " ", $(rel.n == nil), " ", $(rel.ibs == nil)
    result = false
    return

  var cache = newSeq[int32](vcfs.len)
  var min_depth:int = 6

  var n_samples = bams.len
  for v in vcfs:
    n_samples += v.n_samples

  var last_chrom = ""
  var last_pos = -20000
  var missing = 0 # just track how many missing sites and don't report after 20 per thread.

  for s in sites:
    if s.chrom == last_chrom and s.position - last_pos < 100:
      continue

    rel.sites_tested += 1
    nalts = nalts[0..<0]
    var alt_count = get_bam_alts(bams, s, nalts, min_depth, report=(missing < 20)) + get_vcf_alts(vcfs, s, nalts, cache, min_depth)

    if alt_count.float / n_samples.float < 0.7:
      if alt_count < 0:
        missing += 1
      if missing == 20:
        stderr.write_line "[somalier] not reporting further missing sites from this thread."
      continue

    discard krelated(nalts, rel.ibs, rel.n, rel.hets, rel.homs, rel.shared_hom_alts, n_samples)
    last_chrom = s.chrom
    last_pos = s.position

  p[] = rel


iterator relatedness(r:relation_matrices): relation =
  var sample_names = r.samples

  for sj in 0..<r.n_samples - 1:
    for sk in sj + 1..<r.n_samples:
      if sj == sk: quit "logic error"

      var bottom = min(r.hets[sk], r.hets[sj]).float64
      if bottom == 0:
        bottom = max(r.hets[sk], r.hets[sj]).float64
      if bottom == 0:
        # can't calculate relatedness
        bottom = -1'f64

      #var grelatedness = (r.ibs[sk * r.n_samples + sj].float64 - 2 * r.ibs[sj * r.n_samples + sk].float64) / bottom
      #
      yield relation(sample_a: sample_names[sj],
                     sample_b: sample_names[sk],
                     hets_a: r.hets[sj], hets_b: r.hets[sk],
                     hom_alts_a: r.homs[sj], hom_alts_b: r.homs[sk],
                     ibs0: r.ibs[sj * r.n_samples + sk],
                     shared_hets: r.ibs[sk * r.n_samples + sj],
                     shared_hom_alts: r.shared_hom_alts[sj * r.n_samples + sk],
                     ibs2: r.n[sk * r.n_samples + sj],
                     n: r.n[sj * r.n_samples + sk])

proc reorder_1d[T](arr:seq[T], order: seq[int]): seq[T] =
  result = newSeq[T](arr.len)
  for i, o in order:
    result[i] = arr[o]

proc reorder_flat[T](arr:var seq[T], order: seq[int], n:int): seq[T] =
  result = newSeq[T](arr.len)

  for j in 0..<n:
    for i in 0..<n:
      var
        oi = order[i]
        oj = order[j]
      # these flips are required because we store different data in the upper
      # and lower halves of the matrix
      if i < j and oi > oj or i > j and oi < oj:
        var tmp = oi
        oi = oj
        oj = tmp

      result[i*n+j] = arr[oi * n + oj]


proc reorder(r:var relation_matrices, order: seq[int]) =
  # after clustering, we have to re-order similar samples together. 
  var n = r.n_samples

  r.ibs = reorder_flat(r.ibs, order, n)
  r.n = reorder_flat(r.n, order, n)
  r.shared_hom_alts = reorder_flat(r.shared_hom_alts, order, n)

  r.samples = reorder_1d(r.samples, order)
  r.homs = reorder_1d(r.homs, order)
  r.hets = reorder_1d(r.hets, order)

proc cluster(r: var relation_matrices) =
  ## re-order based on the complete linkage so that a heatmap is clustered properly.
  var n = r.n_samples
  var dist = newSeq[seq[float32]](n) # note that this is actually similarity, not distance.

  for sj in 0..<n:
    dist[sj] = newSeq[float32](n)
    dist[sj][sj] = float32.high
  
  for sj in 0..<(n - 1):
    for sk in (sj + 1)..<n:
      if sj == sk:
        quit "logic error"
      var bottom = min(r.hets[sj], r.hets[sk]).float32
      var tmp = (r.ibs[sk * n + sj].float32 - 2 * r.ibs[sj * n + sk].float32) / bottom
      dist[sj][sk] = -tmp
      dist[sk][sj] = -tmp

  var clusters = hcluster(dist, -0.5)

  var order = newSeqOfCap[int](n)
  for cluster in clusters:
    order.add(cluster)
  r.reorder(order)

  # now set the clusters to match the new order
  r.clusters = newSeq[seq[string]](len(clusters))
  var off = 0
  for i, c in clusters:
    r.clusters[i] = newSeq[string](c.len)
    for j in 0..<r.clusters[i].len:
      r.clusters[i][j] = r.samples[j + off]
    off += r.clusters[i].len

{.push checks: off, optimization:speed.}
proc toSite(toks: seq[string]): Site =
  result = Site()
  result.chrom = toks[0]
  result.position = parseInt(toks[1]) - 1
  result.ref_allele = toks[3][0]

proc checkSiteRef(s:Site, fai:var Fai) =
  var fa_allele = fai.get(s.chrom, s.position, s.position)[0]
  if s.ref_allele != fa_allele:
    quit "reference base from sites file:" & s.ref_allele & " does not match that from reference: " & fa_allele
{.pop.}

proc siteOrder(a:Site, b:Site): int =
  if a.chrom == b.chrom:
    return cmp(a.position, b.position)
  return cmp(a.chrom, b.chrom)

proc readSites(path: string, fai:var Fai): seq[Site] =
  result = newSeqOfCap[Site](8192)
  var kstr = kstring_t(l:0, m:0, s:nil)
  var hf = hts_open(path.cstring, "r")

  while hts_getline(hf, cint(10), kstr.addr) > 0:
    var line  = $kstr.s
    if line[0] == '#': continue
    var sep = '\t'
    # handle ":" or tab. with ":", there is no id field.
    if line.count(sep) == 0:
      sep = ':'
    var toks = line.strip().split(sep)
    if sep == ':':
      toks.insert(".", 2)

    result.add(toSite(toks))
  if len(result) > 65535:
    stderr.write_line "warning:cant use more than 65535 sites"
  sort(result, siteOrder)
  # check reference after sorting so we get much faster access.
  for i, r in result:
    if i mod 10000 == 0 and i > 0:
      stderr.write_line "[somalier] checked reference for " & $i & " sites"

    checkSiteRef(r, fai)
  fai = nil


proc `%`*(v:uint16): JsonNode =
  new(result)
  result.kind = JInt
  result.num = v.int64

proc readGroups(path:string): seq[seq[string]] =
  result = newSeq[seq[string]]()
  if path == "":
    return

  # expand out a,b,c to a,b, a,c, b,c
  for line in path.lines:
    var row = line.strip().split(",")
    for i, x in row[0..<row.high]:
      for j, y in row[(i+1)..row.high]:
        result.add(@[x, y])

proc write_groups(r: relation_matrices, output_prefix: string) =
  var
    fh_groups:File
  if not open(fh_groups, output_prefix & "groups.tsv", fmWrite):
    quit "couldn't open output file"
  for group in r.clusters:
    #var s = newSeqOfCap[string](group.len)
    #for i in group:
    #  s.add(r.samples[i])
    fh_groups.write_line join(group, ",")
  fh_groups.close()
  stderr.write_line("[somalier] wrote text output to: ",  output_prefix & "tsv")

proc get_sample_names(path: string, fasta: string): seq[string] =
  if path.bam_like:
    var bam: Bam
    open(bam, path)
    var txt = newString(bam.hdr.hdr.l_text)
    copyMem(txt[0].addr, bam.hdr.hdr.text, txt.len)
    for line in txt.split("\n"):
      if line.startsWith("@RG") and "\tSM:" in line:
        var t = line.split("\tSM:")[1].split("\t")[0].strip()
        # TODO: don't do this.
        #t = t.split("_")[0]
        return @[t]


  elif path.endsWith("vcf.gz") or path.endswith(".bcf") or path.endsWith(".bcf.gz") or path.endsWith("vcf.bgz"):
    var vcf: VCF
    if not open(vcf, path):
      quit "could not open " & $path
    return vcf.samples

  stderr.write_line "[somalier] warning couldn't find samples for " & path & " using file names to guess."
  var s = splitFile(path)
  # TODO: remove s.name
  return @[s.name.split("_")[0]]


proc main() =

  var p = initOptParser()

  var
    bv_paths = newSeq[string]()
    sites_path: string
    fasta_path: string
    groups_path: string = ""
    output_prefix: string = "somalier."
    threads = 1

  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if key == "rel": continue
      bv_paths.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h":
        writeHelp()
        continue
      of "threads", "t":
        threads = parseInt(val)
      of "output", "o":
        output_prefix = val.strip(chars={'.'}) & "." & "somalier."
      of "sites", "s":
        sites_path = val
      of "fasta", "f":
        fasta_path = val
      of "groups", "g":
        groups_path = val
      else:
        writeHelp()
    of cmdEnd:
      assert(false)
  if sites_path == nil or sites_path == "":
    echo "must set sites path"
    writeHelp()
    quit(2)
  if fasta_path == nil or fasta_path == "":
    echo "must set fasta path"
    writeHelp()
    quit(2)
  if threads < 1: threads = 1

  var fai: Fai
  if not open(fai, fasta_path):
    quit "couldn't open fasta with fai:" & fasta_path
  var sites = readSites(sites_path, fai)
  var groups = readGroups(groups_path)

  ## need to track samples names from bams first, then vcfs since
  ## thats the order for the alts array.
  var sample_names = newSeqOfCap[string](len(bv_paths))
  var non_bam_sample_names = newSeqOfCap[string](len(bv_paths))

  for i, path in bv_paths:
    if path.bam_like:
      sample_names.add(get_sample_names(path, fasta_path))
    else:
      non_bam_sample_names.add(get_sample_names(path, fasta_path))

  sample_names.add(non_bam_sample_names)

  var
    n_samples = sample_names.len
  if threads < 2:
    threads = 1

  var batch_size = (sites.len / threads).int

  if threads * batch_size < sites.len:
    batch_size += 1

  if threads * batch_size < sites.len:
    quit "logic error. batch size too small"

  var
    results = newSeq[relation_matrices](threads)
    responses = newSeq[FlowVarBase](threads)

  stderr.write_line "[somalier] batch-size:", batch_size, " sites:", len(sites), " threads:" & $threads

  # aggregated from all threads.
  var final = relation_matrices(ibs: newSeq[uint16](n_samples * n_samples),
                              n: newSeq[uint16](n_samples * n_samples),
                              shared_hom_alts: newSeq[uint16](n_samples * n_samples),
                              hets: newSeq[uint16](n_samples),
                              homs: newSeq[uint16](n_samples),
                              samples: sample_names)

  for j in 0..<responses.len:
    results[j] = relation_matrices()
    results[j].ibs = newSeq[uint16](n_samples * n_samples)
    results[j].n = newSeq[uint16](n_samples * n_samples)
    results[j].shared_hom_alts = newSeq[uint16](n_samples * n_samples)
    results[j].hets = newSeq[uint16](n_samples)
    results[j].homs = newSeq[uint16](n_samples)
    results[j].sites_tested = 0
    var imin = j * batch_size
    var imax = min(sites.len, (j + 1) * batch_size)
    responses[j] = spawn relmatrix(bv_paths, sites[imin..<imax], results[j].addr, j)


  for index, fv in responses:
    await(fv)
    #  quit "[somalier] got unexpected value from await"
    var relm = results[index]

    final.sites_tested += relm.sites_tested

    for i, v in relm.n:
      final.n[i] += v
    for i, v in relm.shared_hom_alts:
      final.shared_hom_alts[i] += v
    for i, v in relm.hets:
      final.hets[i] += v
    for i, v in relm.homs:
      final.homs[i] += v
    for i, v in relm.ibs:
      final.ibs[i] += v

  for i, r in results:
    if r.sites_tested == 0:
      stderr.write_line "[somalier] tested 0 sites for batch:", $i

  stderr.write_line "[somalier] sites tested:", $final.sites_tested

  final.cluster
  #final.clusters = @[@[1]]

  var
    fh_tsv:File
    fh_html:File

  if not open(fh_tsv, output_prefix & "tsv", fmWrite):
    quit "couldn't open output file"
  if not open(fh_html, output_prefix & "html", fmWrite):
    quit "couldn't open html output file"

  fh_tsv.write_line '#', header.replace("$", "")

  var j = % final
  if groups.len > 0:
    j["expected-relatedness"] = % [{
      "value": %1,
      "pairs" : %groups
    }]

  

  fh_html.write(tmpl_html.replace("<INPUT_JSON>", $j))
  fh_html.close()
  stderr.write_line("[somalier] wrote interactive HTML output to: ",  output_prefix & "html")



  for rel in relatedness(final):
    fh_tsv.write_line $rel

  final.write_groups(output_prefix)

  fh_tsv.close()
  stderr.write_line("[somalier] wrote groups to: ",  output_prefix & "groups.tsv")


when isMainModule:
  main()
