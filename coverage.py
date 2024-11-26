#!/bin/python3.10

import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
import os
import pathlib

# TODO interpret the output of kcov and print to the terminal

kcov_out = "/tmp/kcov_output"


def run_kcov():
    subprocess.run(["kcov", kcov_out, "./zig-out/bin/test"])


def create_test_bin():
    subprocess.run(["zig", "build", "test:build"])


@dataclass
class ResultFile:
    filename: str
    lines: int
    lines_covered: int

    def __str__(self) -> str:
        return f"{self.div2str()} - {self.filename}"

    def div2str(self) -> str:
        div = round(100 * self.lines_covered / self.lines, 2)
        compare = "100.0%"
        div_str = f"{div}%"
        padding = len(compare) - len(div_str)
        return div_str + (" " * padding)


@dataclass
class Result:
    files: list[ResultFile]

    def __str__(self) -> str:
        ret = ""
        for f in self.files:
            ret += f"{f}\n"
        return ret


def parse_xml(file: str, prefix: str) -> Result:
    ret = Result([])
    # parse xml
    tree = ET.parse(file)

    # get iteration on all elements
    elements = tree.getroot().iter()

    for element in elements:
        # only check for class tags as they represent a file coverage
        if element.tag != "class":
            continue
        # check prefix
        if not element.attrib["filename"].startswith(prefix):
            continue

        result_file = ResultFile(
            filename=element.attrib["filename"].removeprefix(prefix),
            lines=0,
            lines_covered=0,
        )

        # get lines
        lines_tag = element.findall("lines")
        lines = lines_tag[0].findall("line")

        result_file.lines = len(lines)
        for line in lines:
            if int(line.attrib["hits"]) > 0:
                result_file.lines_covered += 1

        assert result_file.lines > 0
        ret.files.append(result_file)

    return ret


file = "kcov_out/cov.xml"

pwd = os.getcwd()
prefix = pwd.removeprefix(pathlib.Path(pwd).parent.parent.__str__())
if prefix[0] == "/":
    prefix = prefix.removeprefix("/")
if prefix[-1] != "/":
    prefix = prefix + "/"


create_test_bin()
run_kcov()
print(parse_xml(file, prefix))
