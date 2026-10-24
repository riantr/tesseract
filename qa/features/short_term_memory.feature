Feature: The short-term memory
  The memory CLI is a small store of key/value pairs. It lives in the process
  that made it, so nothing it remembers outlives the run that remembered it.

  Background:
    Given the "memory" CLI is built

  Scenario: A value I remember can be read back
    When I run the "memory" CLI:
      | put greeting hello world |
      | get greeting |
    Then the output contains "greeting -> hello world"

  Scenario: A key that was never remembered is not there
    When I run the "memory" CLI:
      | get ghost |
    Then the output contains "ghost -> (nothing)"

  Scenario: The memory forgets the least recently used entry when it is full
    When I run the "memory" CLI with a capacity of 2:
      | put a 1 |
      | put b 2 |
      | put c 3 |
      | keys |
    Then the keys are "b, c"

  Scenario: An entry with a lifetime is gone once the clock passes it
    When I run the "memory" CLI on a manual clock:
      | put a x --ttl 1000 |
      | advance 1000 |
      | get a |
    Then the output contains "a -> (nothing)"

  Scenario: An entry without a lifetime is still there
    When I run the "memory" CLI on a manual clock:
      | put a x --ttl 1000 |
      | advance 999 |
      | get a |
    Then the output contains "a -> x"

  Scenario: A scope is a partition of the keyspace
    When I run the "memory" CLI in the scope "work":
      | put todo ship it |
      | scopes |
    Then the output contains "work"

  Scenario: One scope cannot see the keys of another
    When I run the "memory" CLI in the scope "work":
      | put todo ship it |
      | scope default |
      | get todo |
    Then the output contains "todo -> (nothing)"

  Scenario: A forgotten key is gone
    When I run the "memory" CLI:
      | put greeting hello world |
      | del greeting |
      | get greeting |
    Then the output contains "greeting -> (nothing)"

  Scenario: A search finds the entries that look like the query
    When I run the "memory" CLI:
      | put note the cat sat |
      | put other a dog barked |
      | search cat |
    Then the last output line contains "note"
    And the last output line does not contain "other"

  Scenario: A label is what a filtered listing looks at
    When I run the "memory" CLI:
      | put note the cat sat --meta kind=note |
      | put other a dog barked --meta kind=misc |
      | entries --where kind=note |
    Then the output contains "meta kind=note"
    And the output does not contain "meta kind=misc"

  Scenario: The memory says what it has done
    When I run the "memory" CLI:
      | put greeting hello world |
      | get greeting |
      | stats |
    Then the output contains "puts      1"
    And the output contains "hits      1"
    And the output contains "misses    0"
