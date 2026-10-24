Feature: The key/value store
  A tesseract database is a set of records. Each record has a key, a value and
  a place in the lattice, and the command line reaches it with SQL statements.

  This is the surface a person actually touches: type a statement, read what
  came back. The answers are printed in Chinese, because that is the language
  the product speaks to its user.

  Background:
    Given the "tesseract" CLI is built

  Scenario Outline: A key I insert can be read back
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('<key>','<value>'); |
      | SELECT * FROM tesseract WHERE key = '<key>'; |
    Then the run succeeds
    And the query returns 1 record
    And the output contains "键: <key>"
    And the output contains "值: <value>"

    Examples:
      | key   | value |
      | alpha | one   |
      | beta  | two   |

  Scenario: A key that was never inserted is not found
    When I run the "tesseract" CLI:
      | SELECT * FROM tesseract WHERE key = 'ghost'; |
    Then the run succeeds
    And the query returns 0 records
    And the output does not contain "键: ghost"

  Scenario: A statement is one argument, however long it is
    When I run the "tesseract" CLI with the arguments "SELECT * FROM tesseract WHERE key = 'ghost';"
    Then the run succeeds
    And the query returns 0 records

  Scenario: Updating a key changes the value it holds
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('alpha','one'); |
      | UPDATE tesseract SET value = 'two' WHERE key = 'alpha'; |
      | SELECT * FROM tesseract WHERE key = 'alpha'; |
    Then the query returns 1 record
    And the output contains "值: two"
    And the output does not contain "值: one"

  Scenario: A deleted key is gone
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('alpha','one'); |
      | DELETE FROM tesseract WHERE key = 'alpha'; |
      | SELECT * FROM tesseract; |
    Then the query returns 0 records
    And the output does not contain "键: alpha"

  Scenario: A statement the parser does not know is refused
    When I run the "tesseract" CLI:
      | BOGUS; |
    Then the output contains "✗ 失败"
    And the output contains "UNSUPPORTED_SQL"
    And the output contains "unsupported statement"

  Scenario: Every record gets a place of its own in the lattice
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('a','1'); |
      | INSERT INTO tesseract (key,value) VALUES ('b','2'); |
      | .status |
    Then the database holds 2 records
    And the output contains "位置: 1"
    And the output contains "位置: 2"

  Scenario: The database says how many records it holds
    When I run the "tesseract" CLI:
      | INSERT INTO tesseract (key,value) VALUES ('a','1'); |
      | INSERT INTO tesseract (key,value) VALUES ('b','2'); |
      | INSERT INTO tesseract (key,value) VALUES ('c','3'); |
      | .status |
    Then the database holds 3 records
    And the database holds 0 digits
