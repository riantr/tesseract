Feature: Saving a database to a file and reading it back
  The persistence CLI keeps the lattice in memory and writes it to a `.db` file
  when it is asked to. A file it can read again is the whole point of it, and
  a session that opened a file and never wrote one back says so rather than
  losing the work quietly.

  Background:
    Given the "persistence" CLI is built

  Scenario: A record I save is still there when the file is opened
    When I run the "persistence" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('kept','{}',1) AT 1; |
      | .save {dir}/store.db |
    Then the output contains "saved 1 record(s) to"

    When I run the "persistence" CLI:
      | .open {dir}/store.db |
      | SELECT * FROM tesseract; |
    Then the query returns 1 record
    And the output contains "键: kept"
    And the output contains "opened"

  Scenario: The digit a record holds survives the round trip as well
    When I run the "persistence" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('kept','{}',1) AT 1; |
      | .save {dir}/store.db |

    When I run the "persistence" CLI:
      | .open {dir}/store.db |
      | SELECT * FROM tesseract; |
    Then the output contains "数: 1"

  Scenario: The digits of a reopened store still satisfy the sudoku rules
    When I run the "persistence" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('kept','{}',1) AT 1; |
      | .save {dir}/store.db |

    When I run the "persistence" CLI:
      | .open {dir}/store.db |
      | .verify |
    Then the output contains "line violations : 0"
    And the output contains "slab imbalances : 0"

  Scenario: A store that is opened and never saved says so
    When I run the "persistence" CLI:
      | .open {dir}/store.db |
    Then the output contains "note: nothing was saved"

  Scenario: A file that was never written opens as an empty store
    When I run the "persistence" CLI:
      | .open {dir}/never-written.db |
    Then the output contains "0 record(s), 0 rejected"

  Scenario: The file the store is written to is a real file on disk
    When I run the "persistence" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('kept','{}'); |
      | .save {dir}/store.db |
    Then the file "store.db" exists
