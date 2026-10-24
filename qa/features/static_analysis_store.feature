Feature: The static analysis store
  A scan of a project can be captured to a file and stored, so the findings of
  several scans can be looked at side by side. The scan itself is produced
  elsewhere; this tool reads the capture.

  Background:
    Given the "static analysis" CLI is built
    And a captured static analysis scan is available

  Scenario: A scan is stored and can be shown again
    When I store the captured scan in "{dir}/scan.db"
    Then the output contains "stored run 1 in"

    When I show the stored run in "{dir}/scan.db"
    Then the output contains "12/39 files read end to end"
    And the output contains "actionable : 4"

  Scenario: The stored run says how much of the project was read
    When I store the captured scan in "{dir}/scan.db"
    When I show the stored run in "{dir}/scan.db"
    Then the output contains "coverage"
    And the output contains "not read  : 0 more files"

  Scenario: The files the analyzer could not read are listed apart
    When I store the captured scan in "{dir}/scan.db"
    When I list the files of the stored run in "{dir}/scan.db"
    Then the output contains "read only up to a parse error"

  Scenario: Every stored run is listed side by side
    When I store the captured scan in "{dir}/scan.db"
    When I list the stored runs in "{dir}/scan.db"
    Then the output contains "actionable"
    And the output contains "5193"

  Scenario: A file that is not a completed scan is refused
    When I run the "static analysis" CLI:
      | store |
      | {root}/moon.mod |
      | {dir}/scan.db |
    Then the error output contains "is not a completed scan"

  Scenario: A database with no runs in it says so
    When I show the stored run in "{dir}/empty.db"
    Then the error output contains "no runs in"
