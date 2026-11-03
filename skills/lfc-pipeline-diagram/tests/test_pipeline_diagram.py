"""Offline checks of pipeline-diagram.py on saved pipeline, gateway and connection JSON (names are placeholders)."""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "pipeline-diagram.py")


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], check=True, capture_output=True, text=True).stdout


def f(name):
    return os.path.join(HERE, name)


class Gateway(unittest.TestCase):
    def setUp(self):
        self.out = run("--pipeline-json", f("gateway-pipeline.json"), "--gateway-json", f("gateway-gateway.json"),
                       "--connection-json", f("gateway-connection.json"),
                       "--workspace-host", "https://adb-1.2.azuredatabricks.net", "--source-cloud", "azure",
                       "--source-host", "VM + Podman", "--primary", "203.0.113.10,30005",
                       "--secondary", "203.0.113.10,30006", "--firewall", "NSG", "--secret-kind", "uc")

    def test_text(self):
        self.assertIn("[primary]   [secondary*]", self.out)
        self.assertIn("gateway demo_ag_gw (classic cluster, continuous)", self.out)
        self.assertIn("staging: main.demo_ag_stg", self.out)
        self.assertIn("<-- UC secret", self.out)
        self.assertIn("Databricks (Azure)", self.out)

    def test_mermaid(self):
        self.assertIn("flowchart TD", self.out)
        self.assertIn("N0 -. availability group .-> N1", self.out)
        self.assertIn("N1 --- FW --- C", self.out)  # the connection points at the secondary
        self.assertIn("G --> STG --> A", self.out)


class Integrated(unittest.TestCase):
    def test_integrated(self):
        out = run("--pipeline-json", f("integrated-pipeline.json"), "--connection-json", f("integrated-connection.json"),
                  "--workspace-host", "https://x.cloud.databricks.com", "--hide-host")
        self.assertIn("(integrated CDC, serverless): extract -> staging -> apply", out)
        self.assertIn("streaming tables (SCD 2)", out)
        self.assertIn("Databricks (AWS)", out)
        self.assertNotIn("1433", out)  # --hide-host
        self.assertIn("X[extract] --> STG[(staging volume)] --> APL[apply]", out)


if __name__ == "__main__":
    unittest.main()
