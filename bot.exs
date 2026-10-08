Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule UtyaFaucet do
  @moduledoc false

  @my_project "Utya Faucet Miniapp"
  @base_url "https://utyamaster.duckdns.org"
  @root __DIR__

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    cond do
      accounts == [] ->
        red("File data.txt is empty, please add your initData entries")
        System.halt(1)

      true ->
        proxies = load_lines("proxy.txt")
        settings = load_settings()

        loop(accounts, proxies, settings, 1)
    end
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> :ok
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      process_account(account, index, proxy)
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    wait = sleep_seconds(settings)
    countdown(wait, "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp process_account(account, index, proxy) do
    label = "account #{index + 1}"

    case fetch_state(account, proxy) do
      {:ok, state} ->
        raw = state.raw

        cond do
          get(raw, "banned", false) ->
            red("#{String.capitalize(label)} is banned and was skipped by the bot")

          get(raw, "frozen", false) ->
            red("#{String.capitalize(label)} is frozen and was skipped by the bot")

          get(raw, "paused", false) ->
            yellow("#{String.capitalize(label)} was paused by the operator and was skipped")

          true ->
            green(
              "Welcome back #{clean_text(get(state.user, "username", "Unknown"), "user")} with #{units(get(raw, "accruedUnits", 0), state.decimals)} UTYA mined"
            )

            state
            |> run_membership(proxy)
            |> run_channel_task(proxy)
            |> run_group_task(proxy)
            |> run_vote_task(proxy)
            |> run_tasks(proxy)
            |> run_streak(proxy)
            |> run_eggs(proxy)
            |> run_spin(proxy)
            |> run_quests(proxy)
            |> run_pond(proxy)
            |> run_gifts(proxy)
            |> report_totals(proxy)
        end

        :ok

      {:error, reason} ->
        red("Failed to fetch account state for #{label} with #{clean_text(reason, "error")}")
    end
  end

  defp run_membership(state, proxy) do
    case call("/api/membership/recheck", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        if get(body, "channel", false) do
          green("Channel membership was rechecked and the account is a member")
        else
          yellow("Channel membership was rechecked and the account is not a member yet")
        end

      {:blocked, _body} ->
        yellow("Channel membership still waits for a manual join on this account")

      {:locked, _body} ->
        yellow("Channel membership check is not available for this account right now")

      {:empty, _body} ->
        yellow("Channel membership check returned nothing for this account")

      {:error, reason} ->
        red("Channel membership check failed with #{clean_text(reason, "error")}")
    end

    state
  end

  defp run_channel_task(state, proxy) do
    pace(3, "Channel join task starts in")

    case call("/api/task/channel", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        if get(body, "credited", false) do
          green(
            "Channel join bonus of #{amount(get(body, "bonus", 0))} UTYA was credited to this account"
          )
        else
          yellow("Channel join bonus was already claimed on this account before")
        end

      {:blocked, body} ->
        yellow(
          "Channel join task still waits for a manual join on #{clean_text(get(body, "channel", "the channel"), "channel")}"
        )

      {:locked, _body} ->
        yellow("Channel join task is not available for this account right now")

      {:empty, _body} ->
        yellow("Channel join task returned nothing for this account")

      {:error, reason} ->
        if join_required?(reason) do
          yellow("Channel join task was skipped because this account has not joined yet")
        else
          red("Channel join task failed with #{clean_text(reason, "error")}")
        end
    end

    state
  end

  defp run_group_task(state, proxy) do
    pace(8, "Group join task starts in")

    case call("/api/task/group", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        if get(body, "credited", false) do
          green("Group join bonus of #{plural(get(body, "eggs", 0), "egg")} was credited to this account")
        else
          yellow("Group join bonus was already claimed on this account before")
        end

      {:blocked, body} ->
        yellow(
          "Group join task still waits for a manual join on #{clean_text(get(body, "link", "the group"), "group")}"
        )

      {:locked, _body} ->
        yellow("Group join task is not available for this account right now")

      {:empty, _body} ->
        yellow("Group join task returned nothing for this account")

      {:error, reason} ->
        if join_required?(reason) do
          yellow("Group join task was skipped because this account has not joined yet")
        else
          red("Group join task failed with #{clean_text(reason, "error")}")
        end
    end

    state
  end

  defp run_vote_task(state, proxy) do
    pace(8, "Group poll vote task starts in")

    case call("/api/task/vote", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        if get(body, "credited", false) do
          green("Group poll vote bonus of #{plural(get(body, "eggs", 0), "egg")} was credited")
        else
          yellow("Group poll vote bonus was already claimed on this account before")
        end

      {:blocked, _body} ->
        yellow("Group poll vote task still waits for a manual join on this account")

      {:locked, _body} ->
        yellow("Group poll vote task is not available for this account right now")

      {:empty, _body} ->
        yellow("Group poll vote task returned nothing for this account")

      {:error, reason} ->
        if join_required?(reason) do
          yellow("Group poll vote task was skipped because this account has not joined yet")
        else
          yellow("Group poll vote task is not open for this account right now")
        end
    end

    state
  end

  defp run_tasks(state, proxy) do
    tasks = get(state.raw, "tasks", [])

    pending =
      if is_list(tasks) do
        Enum.filter(tasks, fn task -> get(task, "id") != nil end)
      else
        []
      end

    case pending do
      [] ->
        yellow("Every available account task was already completed")
        state

      list ->
        {claimed, failed} = walk_tasks(list, state, proxy, 0, 0)

        cond do
          claimed > 0 ->
            green(
              "All available tasks completed for this account and #{claimed} rewards were claimed"
            )

          failed > 0 ->
            yellow("#{plural(failed, "account task")} could not be completed on this run")

          true ->
            yellow("Every available account task was already completed")
        end

        state
    end
  end

  defp walk_tasks([], _state, _proxy, claimed, failed), do: {claimed, failed}

  defp walk_tasks([task | rest], state, proxy, claimed, failed) do
    credited =
      case call("/api/task/claim", %{"initData" => state.account, "taskId" => get(task, "id")}, proxy) do
        {:ok, _body} -> true
        _other -> false
      end

    if rest != [] do
      pace(8, "Next account task in")
    end

    if credited do
      walk_tasks(rest, state, proxy, claimed + 1, failed)
    else
      walk_tasks(rest, state, proxy, claimed, failed + 1)
    end
  end

  defp run_streak(state, proxy) do
    case call("/api/streak/claim", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        day = get(body, "day", 1)
        reward = amount(get(body, "reward", 0))
        eggs = get(body, "bonusEggs", 0)

        green(
          "Daily streak day #{day} was claimed with #{reward} UTYA and #{plural(eggs, "bonus egg")}"
        )

        %{state | raw: Map.put(state.raw, "accruedUnits", get(body, "accruedUnits", get(state.raw, "accruedUnits")))}

      {:blocked, _body} ->
        yellow("Daily streak reward still waits for a manual channel join on this account")
        state

      {:locked, _body} ->
        yellow("Daily streak reward is not available for this account right now")
        state

      {:empty, _body} ->
        yellow("Daily streak reward returned nothing for this account")
        state

      {:error, reason} ->
        if already_done?(reason) do
          yellow("Daily streak reward was already claimed on this account today")
        else
          red("Daily streak claim failed with #{clean_text(reason, "error")}")
        end

        state
    end
  end

  defp run_eggs(state, proxy) do
    left = get(get(state.raw, "egg", %{}), "cracksLeft", 0)

    cond do
      not is_number(left) or left <= 0 ->
        yellow("No egg is left to crack on this account for today")
        state

      true ->
        count = left
        pace(3, "Egg cracking starts in")

        case call("/api/egg/crack", %{"initData" => state.account, "count" => count}, proxy) do
          {:ok, body} ->
            results = get(body, "results", [])
            cracked = get(body, "cracked", count)
            hatched = Enum.count(results, fn entry -> get(entry, "hatched") != nil end)
            reward = Enum.reduce(results, 0.0, fn entry, acc -> acc + to_number(get(entry, "reward", 0), 0.0) end)

            green(
              "Cracked #{plural(cracked, "egg")} for #{amount(reward)} UTYA and #{plural(hatched, "hatched duck")}"
            )

            %{state | raw: Map.put(state.raw, "egg", get(body, "egg", get(state.raw, "egg")))}

          {:blocked, _body} ->
            yellow("Egg cracking still waits for a manual channel join on this account")
            state

          {:locked, _body} ->
            yellow("Egg cracking is not available for this account right now")
            state

          {:empty, _body} ->
            yellow("Egg cracking returned nothing for this account")
            state

          {:error, reason} ->
            if join_required?(reason) do
              yellow("Egg cracking was skipped because this account has not joined yet")
            else
              red("Egg cracking failed with #{clean_text(reason, "error")}")
            end

            state
        end
    end
  end

  defp run_spin(state, proxy) do
    state = settle_spin(state, proxy)

    case call("/api/spin/free", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        label = clean_text(get(body, "label", "a reward"), "reward")

        green("Free fortune spin paid #{label} to this account")

        settle_spin(state, proxy)

      {:empty, body} ->
        minutes = round_in(get(body, "nextInMs", 0))
        yellow("Free fortune spin is still regenerating and will be ready in #{minutes} minutes")
        state

      {:blocked, _body} ->
        yellow("Free fortune spin still waits for a manual channel join on this account")
        state

      {:locked, _body} ->
        yellow("Free fortune spin is not available for this account right now")
        state

      {:error, reason} ->
        if join_required?(reason) do
          yellow("Free fortune spin was skipped because this account has not joined yet")
        else
          red("Free fortune spin failed with #{clean_text(reason, "error")}")
        end

        state
    end
  end

  defp settle_spin(state, proxy) do
    case call("/api/spin/result", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        case get(body, "result") do
          nil ->
            state

          result ->
            label = clean_text(get(result, "label", "a reward"), "reward")
            green("Pending fortune spin was settled with #{label} for this account")
            pace(4, "Next spin step in")
            state
        end

      _other ->
        state
    end
  end

  defp run_quests(state, proxy) do
    quests = get(state.raw, "quests", [])

    pending =
      if is_list(quests) do
        Enum.filter(quests, fn quest ->
          get(quest, "complete", false) and not get(quest, "claimed", false)
        end)
      else
        []
      end

    case pending do
      [] ->
        yellow(quest_status(quests))
        state

      list ->
        green("Found #{plural(length(list), "quest")} that can be claimed right now")
        walk_quests(list, state, proxy, 0, 0)
    end
  end

  defp quest_status(quests) do
    cond do
      not is_list(quests) or quests == [] ->
        "No quest is available on this account yet"

      Enum.any?(quests, fn quest -> not get(quest, "claimed", false) end) ->
        "No quest is ready to be claimed on this account yet"

      true ->
        "Every available quest was already completed on this account"
    end
  end

  defp walk_quests([], state, _proxy, claimed, skipped) do
    if skipped > 0 do
      yellow(
        "#{plural(skipped, "quest")} could not be claimed without a manual channel join first"
      )
    end

    if claimed == 0 and skipped == 0 do
      yellow("No quest could be claimed on this run")
    end

    state
  end

  defp walk_quests([quest | rest], state, proxy, claimed, skipped) do
    title = clean_text(get(quest, "title", "quest"), "quest")
    id = get(quest, "id")

    case call("/api/quest/claim", %{"initData" => state.account, "questId" => id}, proxy) do
      {:ok, body} ->
        green(
          "Quest #{title} was claimed for #{get(body, "rewardHuman", "0")} #{reward_unit(body)}"
        )

        pace(4, "Next quest in")
        walk_quests(rest, state, proxy, claimed + 1, skipped)

      {:blocked, _body} ->
        pace(4, "Next quest in")
        walk_quests(rest, state, proxy, claimed, skipped + 1)

      {:locked, _body} ->
        pace(4, "Next quest in")
        walk_quests(rest, state, proxy, claimed, skipped + 1)

      {:empty, _body} ->
        pace(4, "Next quest in")
        walk_quests(rest, state, proxy, claimed, skipped + 1)

      {:error, reason} ->
        text = clean_text(reason, "error")

        if join_required?(text) do
          pace(4, "Next quest in")
          walk_quests(rest, state, proxy, claimed, skipped + 1)
        else
          red("Quest #{title} was refused with #{text}")
          walk_quests(rest, state, proxy, claimed, skipped)
        end
    end
  end

  defp run_pond(state, proxy) do
    case call("/api/pond", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        if get(body, "enabled", false) do
          pond = get(body, "pond", %{})
          feathers = get(pond, "feathers", 0)

          case call("/api/pond/claim", %{"initData" => state.account}, proxy) do
            {:ok, claimed} ->
              claimed = get(claimed, "claimed", 0)

              if is_number(claimed) and claimed > 0 do
                green("Duck pond produced #{plural(claimed, "feather")} and they were claimed")
              else
                yellow("Duck pond holds #{plural(feathers, "feather")} and nothing is ready yet")
              end

            {:blocked, _body} ->
              yellow("Duck pond claim still waits for a manual channel join on this account")

            {:locked, _body} ->
              yellow("Duck pond is still locked and could not be claimed from")

            {:empty, _body} ->
              yellow("Duck pond claim returned nothing for this account")

            {:error, reason} ->
              red("Duck pond claim failed with #{clean_text(reason, "error")}")
          end
        else
          yellow("Duck pond is closed for this account right now")
        end

        state

      {:locked, body} ->
        yellow(
          "Duck pond is still locked with #{clean_text(get(body, "error", "a level requirement"), "requirement")}"
        )

        state

      {:blocked, _body} ->
        yellow("Duck pond still waits for a manual channel join on this account")
        state

      {:empty, _body} ->
        yellow("Duck pond returned nothing for this account")
        state

      {:error, reason} ->
        red("Duck pond state request failed with #{clean_text(reason, "error")}")
        state
    end
  end

  defp run_gifts(state, proxy) do
    case call("/api/gifts", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        gifts = get(body, "gifts", [])

        if is_list(gifts) and gifts != [] do
          green("Found #{plural(length(gifts), "gift box")} waiting to be opened")
          Enum.reduce(gifts, state, fn gift, acc -> open_gift(gift, acc, proxy) end)
        else
          yellow("No gift box is waiting to be opened on this account")
          state
        end

      {:blocked, _body} ->
        yellow("Gift box list still waits for a manual channel join on this account")
        state

      {:locked, _body} ->
        yellow("Gift box list is not available for this account right now")
        state

      {:empty, _body} ->
        yellow("Gift box list returned nothing for this account")
        state

      {:error, reason} ->
        red("Gift box list request failed with #{clean_text(reason, "error")}")
        state
    end
  end

  defp open_gift(gift, state, proxy) do
    id = get(gift, "id")
    name = clean_text(get(gift, "name", "gift box"), "gift box")

    case call("/api/gifts/open", %{"initData" => state.account, "id" => id}, proxy) do
      {:ok, body} ->
        prizes = get(body, "prizes", [])
        green("Gift box #{name} was opened with #{plural(length(prizes), "prize")} inside")
        pace(4, "Next gift box in")
        state

      {:error, reason} ->
        red("Gift box #{name} could not be opened with #{clean_text(reason, "error")}")
        state

      _other ->
        yellow("Gift box #{name} was skipped because it is not openable right now")
        state
    end
  end

  defp report_totals(state, proxy) do
    case call("/api/me", %{"initData" => state.account}, proxy) do
      {:ok, body} ->
        decimals = get(body, "decimals", state.decimals)
        egg = get(body, "egg", %{})
        level = get(get(body, "level", %{}), "level", 1)

        green(
          "Account finished level #{level} with #{units(get(body, "accruedUnits", 0), decimals)} UTYA mined and #{plural(get(egg, "cracksLeft", 0), "egg crack")} remaining"
        )

        %{state | raw: body, decimals: decimals}

      _other ->
        state
    end
  end

  defp fetch_state(account, proxy) do
    case call("/api/me", %{"initData" => account}, proxy) do
      {:ok, body} ->
        {:ok,
         %{
           account: account,
           raw: body,
           user: get(body, "user", %{}),
           decimals: get(body, "decimals", 9),
           eggs_cracked: %{}
         }}

      {:blocked, body} ->
        {:error,
         "the account has not joined #{clean_text(get(body, "channel", "the channel"), "channel")} yet"}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, "account state request returned nothing"}
    end
  end

  defp call(path, payload, proxy) do
    case request(path, payload, proxy) do
      {:ok, body} -> classify(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify(body) do
    cond do
      get(body, "ok", false) ->
        {:ok, body}

      get(body, "nofree", false) ->
        {:empty, body}

      get(body, "locked", false) ->
        {:locked, body}

      get(body, "needChannel", false) or get(body, "needJoin", false) ->
        {:blocked, body}

      true ->
        {:error, get(body, "error", "request was refused")}
    end
  end

  defp request(path, payload, proxy) do
    url = String.to_charlist(@base_url <> path)
    body = YuurisanJSON.encode(payload)
    {profile, auth} = proxy_setup(proxy)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"*/*"},
      {~c"accept-language", ~c"en-US,en;q=0.9"},
      {~c"origin", String.to_charlist(@base_url)},
      {~c"referer", String.to_charlist(@base_url <> "/")},
      {~c"user-agent",
       ~c"Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
    ]

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           options,
           [body_format: :binary],
           profile
         ) do
      {:ok, {{_, status, _}, _, response}} ->
        case YuurisanJSON.decode(response) do
          {:ok, value} -> {:ok, value}
          {:error, _} -> {:error, "server returned status #{status}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _ -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _ -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _ -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _ -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _ -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _ ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil

  defp proxy_for(proxies, index) do
    Enum.at(proxies, rem(index, length(proxies)))
  end

  defp join_required?(text) do
    lowered = String.downcase(text)

    String.contains?(lowered, "join") or
      String.contains?(lowered, "member") or
      String.contains?(lowered, "channel") or
      String.contains?(lowered, "group")
  end

  defp already_done?(text) do
    String.contains?(String.downcase(text), "already")
  end

  defp reward_unit(body) do
    case get(body, "rewardType", "utya") do
      "xp" -> "XP"
      "eggs" -> "eggs"
      "feathers" -> "feathers"
      _ -> "UTYA"
    end
  end

  defp to_number(value, _fallback) when is_number(value), do: value
  defp to_number(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> fallback
    end
  end

  defp to_number(_value, fallback), do: fallback

  defp amount(value) do
    :erlang.float_to_binary(to_number(value, 0.0) * 1.0, decimals: 2)
  end

  defp units(value, decimals) when is_integer(decimals) and decimals >= 0 do
    :erlang.float_to_binary(to_number(value, 0.0) / :math.pow(10, decimals), decimals: 2)
  end

  defp units(value, _decimals), do: amount(value)

  defp round_in(value) do
    case to_number(value, 0) do
      number when is_number(number) -> max(0, round(number / 60_000))
      _ -> 0
    end
  end

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _} -> default_settings()
        end

      {:error, _} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _ -> 3600
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp clean_text(value, fallback) when is_list(value) do
    clean_text(List.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_atom(value) do
    clean_text(Atom.to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_number(value) do
    clean_text(to_string(value), fallback)
  end

  defp clean_text(value, fallback) when is_binary(value) do
    text =
      value
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp clean_text(_value, fallback), do: fallback

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    try do
      System.trap_signal(:sigint, handler)
    rescue
      _ -> :ok
    end

    try do
      System.trap_signal(:sigterm, handler)
    rescue
      _ -> :ok
    end
  end

  defp plural(count, word) do
    if count == 1 do
      "#{count} #{word}"
    else
      "#{count} #{pluralize(word)}"
    end
  end

  defp pluralize(word) do
    if String.ends_with?(word, "y") do
      String.slice(word, 0, String.length(word) - 1) <> "ies"
    else
      word <> "s"
    end
  end

  defp pace(seconds, label) do
    countdown(seconds, label)
    :ok
  end

  defp countdown(seconds, label) do
    left = max(seconds, 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

UtyaFaucet.run()
