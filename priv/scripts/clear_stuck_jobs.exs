import Ecto.Query

{count, _} =
  Spectabas.ObanRepo.update_all(
    from(j in Oban.Job,
      where: j.state == "executing" and j.attempted_at < ago(1, "hour")
    ),
    set: [state: "discarded", discarded_at: DateTime.utc_now()]
  )

IO.puts("Cleared #{count} stuck jobs")
