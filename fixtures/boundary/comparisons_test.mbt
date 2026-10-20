// `below` and `above` are only checked strictly around the threshold, so
// their equality-only boundary mutants survive. `at_most` and `at_least`
// also exercise the threshold itself, so their boundary mutants are killed.

///|
test "below only checks the values around the threshold" {
  inspect(below(9), content="true")
  inspect(below(11), content="false")
}

///|
test "at_most includes the threshold" {
  inspect(at_most(9), content="true")
  inspect(at_most(10), content="true")
  inspect(at_most(11), content="false")
}

///|
test "above only checks the values around the threshold" {
  inspect(above(11), content="true")
  inspect(above(9), content="false")
}

///|
test "at_least includes the threshold" {
  inspect(at_least(11), content="true")
  inspect(at_least(10), content="true")
  inspect(at_least(9), content="false")
}
