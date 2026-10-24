Feature: The shape of the lattice
  The database lives in a four-dimensional lattice of `side x side x side x side`
  cells. Three cells per axis is the default, because that is the size every
  existing file was written under, and `--side` asks for another one.

  Background:
    Given the "tesseract" CLI is built

  Scenario: The default lattice has three cells per axis
    When I run the "tesseract" CLI:
      | .status |
    Then the output contains "3x3x3x3 (81 cells)"
    And the lattice has 3 cells per axis
    And the database holds 0 records
    And the database holds 0 digits

  Scenario: A lattice of four cells per axis has 256 cells
    When I run the "tesseract" CLI with a lattice of 4 cells per axis:
      | .status |
    Then the output contains "4x4x4x4 (256 cells)"
    And the lattice has 4 cells per axis

  Scenario: The size may also be written as one argument
    When I run the "tesseract" CLI:
      | --side=4 |
      | .status |
    Then the output contains "4x4x4x4 (256 cells)"

  Scenario: A lattice bigger than the store can address is refused
    When I run the "tesseract" CLI with a lattice of 999 cells per axis:
      | .status |
    Then the error output contains "is above the maximum 215"
    And the output does not contain "records :"

  Scenario: A size that is not a number is refused
    When I run the "tesseract" CLI:
      | --side |
      | wide |
      | .status |
    Then the error output contains "--side needs an integer"

  Scenario: The cursor moves to the cell it is given
    When I run the "tesseract" CLI:
      | .pos 5 |
    Then the output contains "cursor -> 5"

  Scenario: A cursor position outside the lattice is refused
    When I run the "tesseract" CLI:
      | .pos 9999 |
    Then the output contains "out of range"

  Scenario: The lattice can be drawn as a grid
    When I run the "tesseract" CLI:
      | .grid |
    Then the output contains "cells: . empty"

  Scenario: The command line lists the commands it understands
    When I run the "tesseract" CLI:
      | .help |
    Then the output contains ".status"
    And the output contains ".export tsr|md|sql"
