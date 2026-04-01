#!/usr/bin/env python


####################################################################
####################################################################


#  Import libraries that are commonly part of the
#  Python run time.

import os
import urllib.request
from glob import glob
from pathlib import Path

from flask import Flask, jsonify, render_template, request, send_from_directory

#  Our custom libraries
#
import libraries.l_getConfig as l_getConfig
import libraries.l_getDBHandle as l_getDBHandle

####################################################################
####################################################################


def f_listSlides(i_slidesDir: str) -> list:
   l_exts = ("*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif")
   l_files = []

   for l_ext in l_exts:
      l_files.extend(glob(os.path.join(i_slidesDir, l_ext)))
   l_files = sorted(set(l_files))

   return [os.path.basename(l_file) for l_file in l_files]

   ##############################


def f_loadConfig(i_baseDir: str) -> dict:
   l_cfg = l_getConfig.f_configFile(i_baseDir, "properties.ini")

   r_return = {}

   r_return["DATABASE_HOST"] = l_cfg.get(
      "database", "DATABASE_HOST", fallback="127.0.0.1"
   ).strip()
   r_return["DATABASE_PORT"] = l_cfg.get(
      "database", "DATABASE_PORT", fallback="5433"
   ).strip()

   r_return["DATABASE_NAME"] = l_cfg.get(
      "database", "DATABASE_NAME", fallback="my_dbnw"
   ).strip()

   r_return["DATABASE_USER"] = l_cfg.get(
      "database", "DATABASE_USER", fallback="yugabyte"
   ).strip()
   r_return["DATABASE_PASSWORD"] = l_cfg.get(
      "database", "DATABASE_PASSWORD", fallback=""
   ).strip()

   r_return["YBAMIN_HOSTS"] = l_cfg.get(
      "database", "YBAMIN_HOSTS", fallback=""
   ).strip()

   return r_return


####################################################################
####################################################################


#  Database handle helpers
#


def f_dbGetSrceHandle(i_app):
   return i_app.config["DB_HANDLE_NAME"]


####################################################################
####################################################################


def f_appCreate(i_baseDir: str) -> Flask:
   #  Create the Flask app
   #
   l_app = Flask(__name__)

   #  Set flask defaults for locating files
   #
   l_staticDir = os.path.join(i_baseDir, "static")
   l_templateDir = os.path.join(i_baseDir, "views")
   #
   l_app.static_folder = l_staticDir
   l_app.template_folder = l_templateDir

   ##############################

   #  Config work
   #
   l_cfg = f_loadConfig(i_baseDir)

   l_app.config["CFG"] = l_cfg
   l_app.config["SLIDES_DIR"] = os.path.join(i_baseDir, "slides")

   l_app.config["DB_HANDLE_NAME"] = l_getDBHandle.f_DBHandle(
      l_cfg["DATABASE_HOST"],
      l_cfg["DATABASE_PORT"],
      l_cfg["DATABASE_NAME"],
      l_cfg["DATABASE_USER"],
      l_cfg["DATABASE_PASSWORD"],
      THIS_PROGRAM,
   )
   l_app.config["DB_HANDLE_NAME"].autocommit = True

   ##############################
   ##############################

   #  Beneath this point, our pages
   #
   #  The first few are mostly static
   #

   @l_app.get("/")
   def home():
      return render_template("60_index.html")

   @l_app.get("/slides/<path:filename>")
   def slides_file(filename):
      return send_from_directory(l_app.config["SLIDES_DIR"], filename)

   @l_app.get("/api/slides")
   def api_slides():
      l_files = f_listSlides(l_app.config["SLIDES_DIR"])

      return jsonify({"files": l_files, "count": len(l_files)})

   ##############################

   @l_app.get("/api/geoserver")
   def api_geoserver():
      l_viewparams = request.args.get("viewparams", "")

      l_url = (
         "http://localhost:8080/geoserver/yugabyte/wfs"
         "?service=WFS&version=1.0.0"
         "&request=GetFeature&typeName=yugabyte:my_mapdata_fast"
         "&outputFormat=application/json"
         "&maxFeatures=5000"
         "&viewparams=" + urllib.request.quote(l_viewparams, safe="")
      )

      # Parse viewparams into a dict  (e.g. "LON_MIN:-105.09;LAT_MIN:40.57;...")
      l_params = {}
      for l_pair in l_viewparams.split(";"):
         if ":" in l_pair:
            l_key, l_val = l_pair.split(":", 1)
            l_params[l_key.strip()] = l_val.strip()

      l_browserUrl = (
         "http://localhost:8080/geoserver/yugabyte/wfs"
         "?service=WFS&version=1.0.0"
         "&request=GetFeature&typeName=yugabyte:my_mapdata_fast"
         "&outputFormat=application/json"
         "&maxFeatures=5000"
         "&viewparams=" + l_viewparams
      )

      l_sql = (
         "EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)\n"
         "SELECT\n"
         "   md_pk, md_name, md_address, md_city,\n"
         "   md_province, md_postcode, md_category,\n"
         "   md_subcategory, geom\n"
         "FROM\n"
         "   my_mapdata\n"
         "WHERE\n"
         "   LEFT(geo_hash10, 5) = ANY(\n"
         "      ARRAY(SELECT geohash_cells_for_bbox(\n"
         "         {LON_MIN},\n"
         "         {LAT_MIN},\n"
         "         {LON_MAX},\n"
         "         {LAT_MAX},\n"
         "         5\n"
         "      ))\n"
         "   );\n"
      ).format(**l_params)

      print("\n" + "=" * 70)
      print("GeoServer URL (paste in browser):")
      print("=" * 70)
      print(l_browserUrl)
      print("\n" + "=" * 70)
      print("yugabyteDB SQL (paste in ysqlsh):")
      print("=" * 70)
      print(l_sql)

      with urllib.request.urlopen(l_url, timeout=15) as l_resp:
         l_data = l_resp.read()

      return l_app.response_class(l_data, mimetype="application/json")

   ##############################

   return l_app


####################################################################
####################################################################


THIS_PROGRAM = "60_index - yugabyteDB Geohash Performance"

#  Our program main
#
if __name__ == "__main__":
   BASE_DIR = str(Path(__file__).resolve().parent)

   l_app = f_appCreate(BASE_DIR)
   l_app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5011")), debug=True)




