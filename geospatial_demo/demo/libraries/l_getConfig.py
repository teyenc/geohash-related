import configparser
import os


def f_configFile(i_baseDir: str, i_filename: str) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    cfg.read(os.path.join(i_baseDir, i_filename))
    return cfg
