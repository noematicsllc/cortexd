/*
 * Minimal NIF to get peer credentials from Unix domain sockets.
 * Returns {pid, uid, gid} for the peer process.
 *
 * Linux: Uses SO_PEERCRED (returns pid, uid, gid)
 * macOS/BSD: Uses getpeereid() (returns uid, gid; pid is 0)
 */

#ifdef __APPLE__
#include <erl_nif.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#else
#define _GNU_SOURCE
#include <erl_nif.h>
#include <sys/socket.h>
#include <sys/un.h>
#endif

static ERL_NIF_TERM
get_peercred(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    int fd;

    if (!enif_get_int(env, argv[0], &fd)) {
        return enif_make_badarg(env);
    }

#ifdef __APPLE__
    /* macOS/BSD: use getpeereid() - no pid available */
    uid_t uid;
    gid_t gid;

    if (getpeereid(fd, &uid, &gid) == -1) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "peercred_failed"));
    }

    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        enif_make_tuple3(env,
            enif_make_int(env, 0),  /* pid not available on macOS */
            enif_make_uint(env, uid),
            enif_make_uint(env, gid)));
#else
    /* Linux: use SO_PEERCRED */
    struct ucred cred;
    socklen_t len = sizeof(cred);

    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == -1) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "peercred_failed"));
    }

    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        enif_make_tuple3(env,
            enif_make_int(env, cred.pid),
            enif_make_uint(env, cred.uid),
            enif_make_uint(env, cred.gid)));
#endif
}

static ErlNifFunc nif_funcs[] = {
    {"get_peercred", 1, get_peercred}
};

ERL_NIF_INIT(Elixir.Cortex.Peercred, nif_funcs, NULL, NULL, NULL, NULL)
