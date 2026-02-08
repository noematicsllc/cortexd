:ssl.start()

exclude = [:integration]
exclude = if System.find_executable("openssl"), do: exclude, else: [:openssl | exclude]
ExUnit.start(exclude: exclude)
