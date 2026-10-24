Feature: The sudoku rules the digits obey
  Each cell of the lattice may hold one digit, and two cells that share an
  axis-parallel line may not hold the same digit. The command line refuses a
  digit that would break the rule, and it says which digit was already there.

  Positions are numbered from 1. Positions 1 and 2 sit on the same line, so
  they may not hold the same digit; position 5 does not share a line with
  position 1, so it may.

  Background:
    Given the "tesseract" CLI is built

  Scenario: Two cells on the same line may not hold the same digit
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('a','{}',1) AT 1; |
      | INSERT INTO tesseract (key,value,digit) VALUES ('b','{}',1) AT 2; |
    Then the output contains "✗ 失败"
    And the output contains "SUDOKU_CONFLICT"
    And the output contains "Digit 1 already used at position 1"

  Scenario: Two cells on different lines may hold the same digit
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('a','{}',1) AT 1; |
      | INSERT INTO tesseract (key,value,digit) VALUES ('b','{}',1) AT 5; |
      | .status |
    Then the run succeeds
    And the output does not contain "SUDOKU_CONFLICT"
    And the database holds 2 digits

  Scenario: The digit a cell holds is read back with the record
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('a','{}',2) AT 1; |
      | SELECT * FROM tesseract WHERE key = 'a'; |
    Then the query returns 1 record
    And the output contains "数: 2"

  Scenario: A solved lattice breaks no rule
    When I run the "tesseract" CLI:
      | .solve |
      | .verify |
    Then the output contains "placed 81 digits"
    And the output contains "line violations : 0"
    And the output contains "slab imbalances : 0"
    And the output contains "OK - every axis-parallel line holds 1..3"

  Scenario: The neighbours of a cell are the occupied cells on its lines
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('a','{}',1) AT 1; |
      | INSERT INTO tesseract (key,value,digit) VALUES ('b','{}',2) AT 2; |
      | .neighbours 1 |
    Then the query returns 1 record
    And the output contains "键: b"

  Scenario: A cell with no occupied neighbours has none
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value,digit) VALUES ('a','{}',1) AT 1; |
      | .neighbours 1 |
    Then the query returns 0 records
