import psycopg2


def f_DBHandle(host, port, dbname, user, password, app_name=""):
    conn = psycopg2.connect(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password,
        application_name=app_name,
    )
    return conn
