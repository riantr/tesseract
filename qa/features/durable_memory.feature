Feature: The memory that outlives the process
  The durable memory writes itself to a file after every command, so what was
  remembered is still there for the next run. It is the same set of commands
  as the in-process memory; only the place the memory is kept differs.

  Background:
    Given the "durable memory" CLI is built

  Scenario: A value I remember is still there in the next run
    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | put greeting hello world |
    Then the output contains "greeting -> hello world"

    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | get greeting |
    Then the output contains "greeting -> hello world"

  Scenario: The keys of the durable memory are still there in the next run
    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | put greeting hello world |
      | put farewell goodbye |

    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | keys |
    Then the keys are "farewell, greeting"

  Scenario: The durable memory refuses to run without a file
    When I run the "durable memory" CLI:
      | get greeting |
    Then the error output contains "a durable memory needs a file"

  Scenario: The tour is refused, because it would leave entries in the file
    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | demo |
    Then the error output contains "the tour writes into the store"

  Scenario: The index can be rebuilt from the store
    When I run the "durable memory" CLI with the file "{dir}/notes.db" and the index "{dir}/notes.idx":
      | put note the cat sat |
      | index |
    Then the output contains "rows added"

  Scenario: A word can be looked up in the index
    When I run the "durable memory" CLI with the file "{dir}/notes.db" and the index "{dir}/notes.idx":
      | put note the cat sat |
      | index |
      | index-find cat |
    Then the output contains "cat -> default/note"

  Scenario: The file the durable memory keeps is a real file on disk
    When I run the "durable memory" CLI with the file "{dir}/notes.db":
      | put greeting hello world |
    Then the file "notes.db" exists
