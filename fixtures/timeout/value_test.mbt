///|
async test "slow test exceeds the configured mutant timeout" {
  @async.sleep(2000)
  inspect(increment(1), content="2")
}
