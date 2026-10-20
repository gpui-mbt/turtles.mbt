// The `boundary` group is opt-in. Run with `--operators boundary` (or
// `operators = ["boundary"]`) to classify the four mutants below; the
// default run only produces the comparison inversions these functions
// also contain.

///|
pub fn below(x : Int) -> Bool {
  x < 10
}

///|
pub fn at_most(x : Int) -> Bool {
  x <= 10
}

///|
pub fn above(x : Int) -> Bool {
  x > 10
}

///|
pub fn at_least(x : Int) -> Bool {
  x >= 10
}
