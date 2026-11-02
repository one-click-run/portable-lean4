import Mathlib

open BigOperators

example : ∑ i in Finset.range 10, i = 45 := by
  norm_num

def main : IO Unit :=
  IO.println "Hello from portable Lean 4 + Mathlib!"
