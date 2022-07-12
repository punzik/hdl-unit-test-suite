#include <math.h>
#include <stdlib.h>
#include <vpi_user.h>

/* --------------------------- VPI INTERFACE -------------------------------- */

#define MAX_ARGS 8

static int calltf(char *user_data)
{
    vpiHandle systfref, arg_iter;
    vpiHandle arg_hndl[MAX_ARGS];
    struct t_vpi_value argval;
    int arg_cnt = 0;

    for (int i = 0; i < MAX_ARGS; i++)
        arg_hndl[i] = NULL;

    systfref = vpi_handle(vpiSysTfCall, NULL);
    arg_iter = vpi_iterate(vpiArgument, systfref);

    /* ---- Get agruments ---- */
    if (arg_iter != NULL)
        while (arg_cnt < MAX_ARGS &&
               NULL != (arg_hndl[arg_cnt] = vpi_scan(arg_iter)))
            arg_cnt++;

    // function $log2
    if (arg_cnt != 1)
        vpi_printf("ERROR: $log2() wrong argument count\n");
    else {
        double arg, ret;

        // get argument
        argval.format = vpiRealVal;
        vpi_get_value(arg_hndl[0], &argval);
        arg = argval.value.real;

        ret = log2(arg);

        // put return value
        argval.format     = vpiRealVal;
        argval.value.real = ret;
        vpi_put_value(systfref, &argval, NULL, vpiNoDelay);
    }

    for (int i = 0; i < MAX_ARGS; i++)
        if (arg_hndl[i]) vpi_free_object(arg_hndl[i]);

    return 0;
}

static void register_interface(void)
{
    s_vpi_systf_data tf_data;

    tf_data.type        = vpiSysFunc;
    tf_data.sysfunctype = vpiRealFunc;
    tf_data.compiletf   = 0;
    tf_data.sizetf      = 0;
    tf_data.calltf      = calltf;
    tf_data.tfname      = "$log2";
    vpi_register_systf(&tf_data);
}

typedef void (*stfunc)(void);
stfunc vlog_startup_routines[] = {register_interface, 0};
