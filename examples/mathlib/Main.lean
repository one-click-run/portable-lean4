import Mathlib

example : (Finset.range 10).sum (fun i => i) = 45 := by
  norm_num

#check ContinuousLinearMap
