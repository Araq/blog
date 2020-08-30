import perlish

perlish:
  var count = 0
  var s = newSeq[int]()
  while readLine():
    if =~ re"(\d+\s*)+":
      let w = splitWhitespace()
      inc count
      for i in 0..w.high:
        ensureLen s, i+1
        s[i] += w[i]
  for x in s:
    print x / count, "\t"
  print "\n"
