///|
async test "only the boolean mutant starts a persistent helper" {
  if should_timeout() {
    match (
      @env.get_env_var("TURTLES_TIMEOUT_HELPER"),
      @env.get_env_var("TURTLES_TIMEOUT_HELPER_SCRIPT"),
      @env.get_env_var("TURTLES_TIMEOUT_HELPER_TOKEN"),
      @env.get_env_var("TURTLES_TIMEOUT_HELPER_READY"),
    ) {
      (Some(helper), Some(script), Some(token), Some(ready)) => {
        @process.spawn_orphan(
          helper,
          [script, "--persistent-child", token, ready],
        )
        |> ignore
        @async.sleep(120000)
      }
      _ => fail("timeout smoke helper environment is missing")
    }
  }
  inspect(should_timeout(), content="false")
}
