/* $Log: module.h,v $
 * Revision 1.1  1994/10/09  06:42:37  arda
 * Libraries
 * Type inference
 * Many minor improvements
 * */

#ifndef MODULE_H
#define MODULE_H

#include "types.h"

enum { module_unloaded, module_error, module_loading, module_loaded, module_protected };

extern struct table *modules;

int module_status(const char *name);
/* Returns: Status of module name:
     module_unloaded: module has never been loaded, or has been unloaded
     module_error: attempt to load module led to error
     module_loaded: module loaded successfully
     module_protected: module loaded & protected
*/

void module_set(const char *name, int status);
/* Requires: status != module_unloaded
   Effects: Sets module status after load attempt
*/

int module_unload(const char *name);
/* Effects: Removes all knowledge about module 'name' (eg prior to reloading it)
     module_status(name) will return module_unloaded if this operation is
     successful
     Sets to null all variables that belonged to name, and resets their status
     to var_normal
   Returns: FALSE if name was protected
*/

int module_load(const char *name);
/* Effects: Attempts to load module name by calling mudlle hook
     Error/warning messages are sent to muderr
     Sets erred to TRUE in case of error
     Updates module status
   Modifies: erred
   Requires: module_status(name) == module_unloaded
   Returns: New module status
*/

int module_require(const char *name);
/* Effects: Does module_load(name) if module_status(name) == module_unloaded
     Other effects as in module_load
*/

enum { var_normal, var_module, var_write };
int module_vstatus(long n, struct string **name);
/* Returns: status of global variable n:
     var_normal: normal global variable, no writes
     var_write: global variable which is written
     var_module: defined symbol of a module
       module name is stored in *name
   Modifies: name
   Requires: n be a valid global variable offset
*/

int module_vset(long n, int status, struct string *name);
/* Effects: Sets status of global variable n to status.
     name is the module name for status var_module
   Returns: TRUE if successful, FALSE if the change is impossible
     (ie status was already var_module)
*/

void module_init(void);
/* Initialise this module */

#endif
