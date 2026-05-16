/* stb_json - v0.6 - public domain json parser - http://d0n3val.github.org
   no warranty implied; use at your own risk

   Do this:
      #define STB_JSON_IMPLEMENTATION
   before you include this file in *one* C or C++ file to create the implementation.

   // i.e. it should look like this:
   #include ...
   #include ...
   #include ...
   #define STB_JSON_IMPLEMENTATION
   #include "stb_json.h"

   You can #define STBI_ASSERT(x) before the #include to avoid using assert.h.
   This lib has zero dependencies, even against standard libraries. It does not
   allocate any memory in the heap.

   QUICK NOTES:
      Primarily of interest to deploy a non-intrusive json parser

   Full documentation under "DOCUMENTATION" below.

LICENSE AND REVISION HISTORY:

  See end of file

 ============================    Contributors    =========================

 Parsing
    Ricard Pillosu
                                           
 Optimizations & bugfixes

 Bug & warning fixes

*/

#ifndef STBJ_INCLUDE_STB_JSON_H
#define STBJ_INCLUDE_STB_JSON_H

// DOCUMENTATION
//
// Limitations:
//    - no reading from files, only buffers
//    - no writing of json files
//    - not intended for strict/formal parsing
//
// Basic usage example: ---
//
//	char buffer0[] = "{\"name\": \"John\", \"married\": true, \"height\": 181.55, \"eye colors\": [3,3] }";
//
//	stbj_cursor cursor = stbj_load_buffer(buffer0, strlen(buffer0) + 1);
//
//	if (stbj_any_error(&cursor))
//	{
//		printf("Error loading JSON buffer %s", stbj_get_last_error(&cursor));
//	}
//	else
//	{
//		printf("Found %i values at current cursor\n", stbj_count_values(&cursor));
//
//		char buf[10];
//		stbj_read_string_name(&cursor, "name", buf, 10, "not found");
//		printf("Name: %s\n", buf);
//
//		if (stbj_read_int_name(&cursor, "married", 0))
//			printf("... is married\n");
//		else
//			printf("... is not married\n");
//
//		printf("Height is: %0.3f\n", stbj_read_double_name(&cursor, "height", 0.0));
//		printf("Weight is: %0.3f\n", stbj_read_double_name(&cursor, "weight", 0.0)); // does not exist
//
//		stbj_cursor cursor_eyes = stbj_move_cursor_name(&cursor, "eye colors");
//		int left_eye = stbj_read_int_index(&cursor_eyes, 0, -1);
//		int right_eye = stbj_read_int_index(&cursor_eyes, 1, -1);
//
//		printf("Eyes: %i - %i\n", left_eye, right_eye);
//	}
//
// Ouput from example: ---
//
// Found 4 values at current cursor
// Name: John
// ... is married
// Height is: 181.550
// Weight is: 0.000
// Eyes: 3 - 3
//
// TODO ======================================================================
//
// Cannot parse exponents for doubles
// Cannot parse hex, ignored right now (\uFFFF)
// Unicode support
// Benchmark the lib against other json parsers
//
// ===========================================================================
//
// Philosophy
//
// stb libraries are designed with the following priorities:
//
//    1. easy to use
//    2. easy to maintain
//    3. good performance
//
// Sometimes I let "good performance" creep up in priority over "easy to maintain",
// and for best performance I may provide less-easy-to-use APIs that give higher
// performance, in addition to the easy-to-use ones. Nevertheless, it's important
// to keep in mind that from the standpoint of you, a client of this library,
// all you care about is #1 and #3, and stb libraries DO NOT emphasize #3 above all.
//
// Some secondary priorities arise directly from the first two, some of which
// provide more explicit reasons why performance can't be emphasized.
//
//    - Portable ("ease of use")
//    - Small source code footprint ("easy to maintain")
//    - No dependencies ("ease of use")
//
// ===========================================================================
//

#define STBJ_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

#ifndef STBJDEF
#ifdef STB_JSON_STATIC
#define STBJDEF static
#else
#define STBJDEF extern
#endif
#endif

//////////////////////////////////////////////////////////////////////////////
//
// STBJ_CURSOR holds data to parse a buffer from a specific object/array
//
enum cursor_type { STBJ_OBJECT, STBJ_ARRAY, STBJ_ERROR };

typedef struct
{
    enum cursor_type type;
	unsigned int len;
	const char* buffer;
    const char* cursor;
    char error;
} stbj_cursor;

//////////////////////////////////////////////////////////////////////////////
//
// PRIMARY API
//
STBJDEF int			stbj_any_error(const stbj_cursor* context);
STBJDEF const char* stbj_get_last_error(const stbj_cursor* context);
STBJDEF stbj_cursor stbj_load_buffer(const char *buffer, unsigned int len);
STBJDEF int			stbj_count_values(stbj_cursor* context);
STBJDEF stbj_cursor stbj_move_cursor_index(stbj_cursor* context, int index);
STBJDEF stbj_cursor stbj_move_cursor_name(stbj_cursor* context, const char* name);
STBJDEF const char* stbj_find_index(stbj_cursor* context, int index);
STBJDEF int			stbj_find_name(stbj_cursor* context, const char* name);

STBJDEF int			stbj_read_int_index(stbj_cursor* context, int index, int default_value);
STBJDEF int			stbj_read_int_name(stbj_cursor* context, const char* name, int default_value);
STBJDEF double		stbj_read_double_index(stbj_cursor* context, int index, double default_value);
STBJDEF double		stbj_read_double_name(stbj_cursor* context, const char* name, double default_value);
STBJDEF int			stbj_read_string_index(stbj_cursor* context, int index, char* buffer, int buffer_size, const char* default_value);
STBJDEF int			stbj_read_string_name(stbj_cursor* context, const char* name, char* buffer, int buffer_size, const char* default_value);

#ifdef __cplusplus
}
#endif

//
//
////   end header file   /////////////////////////////////////////////////////
#endif // STBJ_INCLUDE_STB_JSON_H

////////////////////////////////////
//
// Start of implementation
//

#ifdef STB_JSON_IMPLEMENTATION

#ifndef STBJ_ASSERT
#include <assert.h>
#define STBJ_ASSERT(x) assert(x)
#endif

#ifdef __cplusplus
#define STBJ_EXTERN extern "C"
#else
#define STBJ_EXTERN extern
#endif

///////////////////////////////////////////////
//
//  Error Handling functions
//
STBJDEF int stbj_any_error(const stbj_cursor* context)
{
    STBJ_ASSERT(context);

    return(context->error);
}

STBJDEF const char* stbj_get_last_error(const stbj_cursor* context)
{
    STBJ_ASSERT(context);

    switch(context->error)
    {
        case 0: return "No error";
        case 1: return "JSON parse error, could not find { or [";
        case 2: return "Element not found in current context";
        case 3: return "JSON parse error, [] or {} mismatch";
        case 4: return "JSON parse error, [] mismatch";
        case 5: return "JSON parse error, {} mismatch";
        case 6: return "Context must be of type Object";
        case 7: return "JSON error parsing string to number";
        case 8: return "JSON error parsing to string";
    }

    return "Unknown error";
}

///////////////////////////////////////////////////////////
//
//  Loading buffers and moving cursors around it
//

// Creates a cursor to parse on that buffer. 
// WARNING: Application should to keep the memory available for reading.
STBJDEF stbj_cursor stbj_load_buffer(const char *buffer, unsigned int len)
{
    STBJ_ASSERT(buffer);
    STBJ_ASSERT(len > 0);

    stbj_cursor context;
    context.len = len;
    context.buffer = buffer;
    context.cursor = buffer;
    context.type = STBJ_ERROR;
    context.error = 1;

    unsigned int max_len = context.len - (unsigned int)(context.cursor - context.buffer);

    while(max_len-- > 0 && *context.cursor) 
    { 
        switch(*context.cursor)
        {
			case ' ': case '\n': case '\r': case '\t': break;
            case '[': context.type = STBJ_ARRAY; context.error = 0; return context;
            case '{': context.type = STBJ_OBJECT; context.error = 0; return context;
            default: return context;
        }
        ++context.cursor;
    }

    return context;
}

// Count the values at the current cursor context. Many nested arrays/objects will count as one.
STBJDEF int stbj_count_values(stbj_cursor* context)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);

    context->error = 0;
    int result = 0;
    int between_comas = 0;
    char stack[256];
    int stack_index = -1;
    char delimiter = (context->type == STBJ_ARRAY) ? ']' : '}';

    const char* cursor = context->cursor;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);

    while(max_len-- > 0 && *++cursor && stack_index < 256) 
    {
        // Two different logics if we are in a nested array/object or not
        if(stack_index < 0)
        {
            // we are on the same array/object level
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': case '}': if(!between_comas && *cursor == delimiter) return ++result; break;
                case ',': result += !between_comas; break;
                case '"': between_comas = !between_comas; break;
            }
        }
        else
        {
            // we are in a nested array/object, keep consuming chars and record progress in out stack
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': 
                    if(stack[stack_index] == '[') --stack_index; 
                    else { context->error = 4; return -1; } 
                break;
                case '}': 
                    if(stack[stack_index] == '{') --stack_index; 
                    else { context->error = 5; return -1; } 
                break;
            }
        }
    }

    context->error = 3;
    return -1;
}

// Returns a new cursor to begin parsing at index. Use it to parse inside an array or object
STBJDEF stbj_cursor stbj_move_cursor_index(stbj_cursor* context, int index)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(index >= 0);

    stbj_cursor ret;
    ret.type = STBJ_ERROR;
    ret.len = context->len;
    ret.buffer = context->buffer;
    ret.cursor = stbj_find_index(context, index);
    ret.error = 1;

    if(ret.cursor != 0)
    {
        unsigned int max_len = context->len - (unsigned int)(ret.cursor - context->buffer);

        // iterate chars
        while(max_len-- > 0 && *ret.cursor) 
        { 
            switch(*ret.cursor)
            {
				case ' ': case '\n': case '\r': case '\t': break;
                case '[': ret.type = STBJ_ARRAY; ret.error = 0; return ret;
                case '{': ret.type = STBJ_OBJECT; ret.error = 0; return ret;
                default: return ret;
            }
            ++ret.cursor;
        }
    }

    return ret; 
}

// Returns a new cursor to begin parsing at _name_. Use it to parse inside an array or object
STBJDEF stbj_cursor stbj_move_cursor_name(stbj_cursor* context, const char* name)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(name);

    int pos = stbj_find_name(context, name);
    if (pos >= 0) 
        return stbj_move_cursor_index(context, pos);

    stbj_cursor ret;
    ret.type = STBJ_ERROR;
    ret.len = 0;
    ret.buffer = 0;
    ret.cursor = 0;
    ret.error = 2;

    return ret;
}

// This function is for internal use only: Return a pointer to the value at index
STBJDEF const char* stbj_find_index(stbj_cursor* context, int index)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(index >= 0);

    context->error = 3;
    int result = 0;
    int between_comas = 0;
    char stack[256];
    int stack_index = -1;
    char delimiter = (context->type == STBJ_ARRAY) ? ']' : '}';

    const char* cursor = context->cursor;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);

    while(max_len-- > 0 && *++cursor && stack_index < 256) 
    {
        if(result == index)
        {
            context->error = 0;

            // if object just consume chars until ':'
            if(context->type == STBJ_OBJECT)
                while(max_len-- > 0 && *cursor && *cursor++ != ':');

            return cursor;
        }

        // Two different logics if we are in a nested array/object or not
        if(stack_index < 0)
        {
            // we are on the same array/object level
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': case '}': if(!between_comas && *cursor == delimiter) return 0; break;
                case ',': result += !between_comas; break;
                case '"': between_comas = !between_comas; break;
            }
        }
        else
        {
            // we are in a nested array/object, keep consuming chars and record progress in our stack
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': 
                    if(stack[stack_index] == '[') --stack_index; 
                    else { context->error = 4; return 0; }
                break;
                case '}': 
                    if(stack[stack_index] == '{') --stack_index;
                    else { context->error = 5; return 0; }
                break;
            }
        }
    }

    return 0;
}

// This function is for internal use only: Returns a pointer at the value after _name_
STBJDEF int stbj_find_name(stbj_cursor* context, const char* name)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(name);

    context->error = 6;
    if(context->type == STBJ_ARRAY)
        return -1;

    context->error = 0;
    int result = 0;
    int between_comas = 0;
    char stack[256];
    int stack_index = -1;

    const char* cursor = context->cursor;
    const char* compare_cursor = name;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);

    while(max_len-- > 0 && *++cursor && stack_index < 256) 
    {
        // Two different logics if we are in a nested array/object or not
        if(stack_index < 0)
        {
            // we are on the same array/object level
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': if(!between_comas) { context->error = 4; return -1; } break;
                case '}': if(!between_comas) { context->error = 5; return -1; } break; 
                case ',': result += !between_comas; break;
                case '"': between_comas = !between_comas; break;
                default:
                    if(between_comas && *compare_cursor == *cursor)
                        { if(*++compare_cursor == 0 && *(cursor+1) == '"') return result; }
                    else
                        compare_cursor = name;
                    break;
            }
        }
        else
        {
            // we are in a nested array/object, keep consuming chars and record progress in our stack
            switch(*cursor)
            {
                case '[': case '{': stack[++stack_index] = *cursor; break;
                case ']': 
                    if(stack[stack_index] == '[') --stack_index; 
                    else { context->error = 4; return -1; }
                break;
                case '}': 
                    if(stack[stack_index] == '{') --stack_index; 
                    else { context->error = 5; return -1; }  
                break;
            }
        }
    }

    context->error = 2;
    return -1;
}

///////////////////////////////////////////////
//
//  Core parsing functions
//

// Try parsing an integer value at index. If unable, return default_value.
STBJDEF int stbj_read_int_index(stbj_cursor* context, int index, int default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(index >= 0);

    const char* cursor = stbj_find_index(context, index);

    if(!cursor)
        return default_value; // error num already set by get_element()

    enum parse_states
    {
        before_value,
        at_num_value,       // 123
        at_special_value,   // true/false/null
        after_value,
        finish,
        error
    } state = before_value;

    context->error = 0;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);
    int between_comas = 0;
    int sign = 1;
    int result = 0;
    int have_result = 0;
    int past_dot = 0;
    char special[] = "rue\0ull\0alse";
    char* c_special = &special[0];

    while(max_len-- > 0 && *cursor && state != finish) 
    {
        switch(state)
        {
            case before_value:
            {
                // Parsing done before encountering any value of meaning -----------------
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '.': --cursor; have_result = 1; state = at_num_value; break;
                    case '"': if(between_comas++) state = finish; break;
                    case '-': sign = -1; // fall to next option
                    case '+': state = at_num_value; have_result = 1; break;
                    case '0': case '1': case '2': case '3': case '4':
                    case '5': case '6': case '7': case '8': case '9': 
                        result = *cursor - '0'; state = at_num_value; have_result = 1; break;
                    case 't': state = at_special_value; have_result = 1; result = 1; break;
                    case 'f': c_special += 8; state = at_special_value; have_result = 1;  break;
                    case 'n': c_special += 4; state = at_special_value; have_result = 1;  break;
                    default: --cursor; state = after_value; break;
                }

            } break;

            case at_num_value:
            {
                // Parsing on a number ---------------------------------------------------
                switch(*cursor)
                {
                    case '.': if(past_dot++) state = error; break;
                    case '0': case '1': case '2': case '3': case '4':
                    case '5': case '6': case '7': case '8': case '9':
                        if(!past_dot) result = (10 * result) + (*cursor - '0'); break;
                    default: --cursor; state = after_value; break;
                }
            } break;

            case at_special_value:
            {
                // Parsing on a special token (true/false/null) --------------------------
                switch(*cursor)
                {
                    case 'r': case 'u':
                    case 'a': case 's':
                        if(*cursor != *c_special++) state = error; break;
                    case 'e':
                        state = (*cursor != *c_special) ? error : after_value; break;
                    case 'l':
                    {
                        if(*cursor != *c_special++)
                            state = error;
                        else 
                            if(*c_special == 0) state = after_value;
                    } break;
                    default: state = error; break;
                }
            } break;

            // We are finish parsing, wait until we end the element ----------------------
            case after_value:
            {
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '"': state = (between_comas) ? after_value : error; break;
                    case ',': state = finish; break;
                    case ']': state = (context->type == STBJ_ARRAY) ? finish : error; break;
                    case '}': state = (context->type == STBJ_OBJECT) ? finish : error; break;
                    default: state = error; break;
                }
            } break;

            case finish: case error: default: STBJ_ASSERT(0 && "this should never happen!"); break;
        }

        // corner case where the error case is not evaluated at the end of max_len ...
        if(state == error)
        {
            context->error = 7; 
            return default_value;
        }
        
        ++cursor;
    }

    return (have_result) ? result * sign : default_value;
}

// Try parsing an integer value at _name_. If unable, return default_value.
STBJDEF int stbj_read_int_name(stbj_cursor* context, const char* name, int default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(name);

    int pos = stbj_find_name(context, name);
    return (pos >= 0) ? stbj_read_int_index(context, pos, default_value) : default_value;
}

// Try parsing a double value at index. If unable, return default_value.
STBJDEF double stbj_read_double_index(stbj_cursor* context, int index, double default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(index >= 0);

    const char* cursor = stbj_find_index(context, index);

    if(!cursor)
        return default_value; // error num already set by get_element()

    enum parse_states
    {
        before_value,
        at_num_value,       // 123
        at_special_value,   // true/false/null
        after_value,
        finish,
        error
    } state = before_value;

    context->error = 0;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);
    int between_comas = 0;
    double sign = 1.0;
    double result = 0.0;
    int have_result = 0;
    double decimal = 1.0;
    int past_dot = 0;
    char special[] = "rue\0ull\0alse";
    char* c_special = &special[0];

    while(max_len-- > 0 && *cursor && state != finish) 
    {
        switch(state)
        {
            case before_value:
            {
                // Parsing done before encountering any value of meaning -----------------
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '"': if(between_comas++) state = finish; break;
                    case '-': sign = -1.0; // fall to next option
                    case '+': state = at_num_value; have_result = 1; break;
                    case '.': past_dot = 1; state = at_num_value; have_result = 1; break;
                    case '0': case '1': case '2': case '3': case '4':
                    case '5': case '6': case '7': case '8': case '9': 
                        result = *cursor - '0'; state = at_num_value; have_result = 1; break;
                    case 't': state = at_special_value; have_result = 1; result = 1; break;
                    case 'f': c_special += 8; state = at_special_value; have_result = 1;  break;
                    case 'n': c_special += 4; state = at_special_value; have_result = 1;  break;
                    default: --cursor; state = after_value; break;
                }

            } break;

            case at_num_value:
            {
                // Parsing on a number ---------------------------------------------------
                switch(*cursor)
                {
                    case '.': if(past_dot++) state = error; break;
                    case '0': case '1': case '2': case '3': case '4':
                    case '5': case '6': case '7': case '8': case '9':
                        result = (10 * result) + (*cursor - '0');
                        if(past_dot) decimal *= 10.0;
                    break;
                    default: --cursor; state = after_value; break;
                }
            } break;

            case at_special_value:
            {
                // Parsing on a special token (true/false/null) --------------------------
                switch(*cursor)
                {
                    case 'r': case 'u':
                    case 'a': case 's':
                        if(*cursor != *c_special++) state = error; break;
                    case 'e':
                        state = (*cursor != *c_special) ? error : after_value; break;
                    case 'l':
                    {
                        if(*cursor != *c_special++)
                            state = error;
                        else 
                            if(*c_special == 0) state = after_value;
                    } break;
                    default: state = error; break;
                }
            } break;

            // We are finish parsing, wait until we end the element ----------------------
            case after_value:
            {
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '"': state = (between_comas) ? after_value : error; break;
                    case ',': state = finish; break;
                    case ']': state = (context->type == STBJ_ARRAY) ? finish : error; break;
                    case '}': state = (context->type == STBJ_OBJECT) ? finish : error; break;
                    default: state = error; break;
                }
            } break;

            case finish: case error: default: STBJ_ASSERT(0 && "this should never happen!"); break;
        }

        // corner case where the error case is not evaluated at the end of max_len ...
        if(state == error)
        {
            context->error = 7; 
            return default_value;
        }
        
        ++cursor;
    }

    return (have_result) ? ((result/decimal) * sign) : default_value; 
}

// Try parsing a double value at _name_. If unable, return default_value.
STBJDEF double stbj_read_double_name(stbj_cursor* context, const char* name, double default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(name);

    int pos = stbj_find_name(context, name);
    return (pos >= 0) ? stbj_read_double_index(context, pos, default_value) : default_value;
}

// Try parsing a string at index and fill provided buffer. If unable, fill the buffer with default_value.
STBJDEF int stbj_read_string_index(stbj_cursor* context, int index, char* buffer, int buffer_size, const char* default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(index >= 0);
    STBJ_ASSERT(buffer);
    STBJ_ASSERT(buffer_size > 0);

    const char* cursor = stbj_find_index(context, index);
    int buffer_index = 0;

    if(!cursor)
    {
        // TODO check if we can avoid replicating this code
        if(default_value != 0)
            while((buffer[buffer_index++] = *default_value++) && buffer_index < (buffer_size-1));
        buffer[buffer_index] = 0;
        return buffer_index;
    }

    enum parse_states
    {
        before_value,
        at_string_value,    // hellot world
        at_special_value,   // true/false/null
		at_scape_character,	// \n \r \b ...
		at_hex_value,		// \uFAFA
        after_value,
        finish,
        error
    } state = before_value;

    context->error = 0;
    unsigned int max_len = context->len - (unsigned int)(cursor - context->buffer);
    int between_comas = 0;
	int hex = 0;
	int hex_count = 0;
    char special[] = "ull";
    char* c_special = &special[0];

    while(max_len-- > 0 && *cursor && state != finish) 
    {
        switch(state)
        {
            case before_value:
            {
                // Parsing done before encountering any value of meaning -----------------
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '"': between_comas = 1; state = at_string_value; break;
                    case 'n': state = at_special_value; break;
                    case '[': case '{': case ']': case '}': case ',': 
                              --cursor; state = after_value; break;
                    default: --cursor; state = at_string_value; break;
                }

            } break;

            case at_string_value:
            {
                // Parsing on a string ---------------------------------------------------
                switch(*cursor)
                {
					case '\\': state = at_scape_character;
                    case '"': --cursor; state = after_value; break;
                    case '[': case '{': case ']': case '}': case ',': 
                        if(!between_comas) { --cursor; state = after_value; } break;
                    default: 
                        if(buffer_index < buffer_size-1) 
                            buffer[buffer_index++] = *cursor; 
                        else
                            state = finish;
                        break;
                }

            } break;

			case at_scape_character:
			{
				// Parsing scape characters like \n or \" -------------------------------------------
				char c = 0;

				switch (*cursor)
				{
					case '\\': c = '\\'; break;
					case '/': c = '/'; break;
					case '"': c = '"'; break;
					case 'b': c = '\b';  break;
					case 'n': c = '\n';  break;
					case 'r': c = '\r';  break;
					case 't': c = '\t';  break;
					case 'f': c = '\f';  break;
					case 'u': state = at_hex_value; break;
					default: state = finish;  break;
				}

				if (state == at_scape_character && buffer_index < buffer_size - 1)
				{
					buffer[buffer_index++] = c;
					state = at_string_value;
				}
			} break;

			case at_hex_value:
			{
				// Parsing scape characters like \uFFFF ---------------------------------------------
				char byte = 0;

				switch (*cursor)
				{
                    case '0': case '1': case '2': case '3': case '4':
                    case '5': case '6': case '7': case '8': case '9':
						byte = *cursor - '0'; break;

					case 'a': case 'b': case 'c': case 'd': case 'e': case 'f':
						byte = 10 + (*cursor - 'a'); break;

					case 'A': case 'B': case 'C': case 'D': case 'E': case 'F':
						byte = 10 + (*cursor - 'A'); break;

					default: state = finish;  break;
				}

				hex = (hex << 4) | (byte & 0xF);

				if (state != finish && ++hex_count >= 4)
				{
					//buffer[buffer_index++] = hex; // TODO: unicode
					hex_count = 0;
					state = at_string_value;
				}

			} break;

            case at_special_value:
            {
                // Parsing on a special token (null) ------------------------------------
                switch(*cursor)
                {
                    case 'u':
                        if(*cursor != *c_special++) state = error; break;
                    case 'l':
                    {
                        if(*cursor != *c_special++)
                            state = error;
                        else 
                            if(*c_special == 0) state = after_value;
                    } break;
                    default: state = error; break;
                }
            } break;

            // We are finish parsing, wait until we end the element ----------------------
            case after_value:
            {
                switch(*cursor)
                {
					case ' ': case '\n': case '\r': case '\t': break;
                    case '"': state = (between_comas) ? after_value : error; break;
                    case ',': state = finish; break;
                    case ']': state = (context->type == STBJ_ARRAY) ? finish : error; break;
                    case '}': state = (context->type == STBJ_OBJECT) ? finish : error; break;
                    default: state = error; break;
                }
            } break;

            case finish: case error: default: STBJ_ASSERT(0 && "this should never happen!"); break;
        }

        // corner case where the error case is not evaluated at the end of max_len ...
        if(state == error)
        {
            context->error = 8; 
            return 0;
        }
        
        ++cursor;
    }

    // if we did not wrote anything, strcpy default value into buffer
    if(buffer_index == 0 && default_value != 0)
        while((buffer[buffer_index++] = *default_value++) && buffer_index < (buffer_size-1));

    buffer[buffer_index] = 0;
    return buffer_index; 
}

// Try parsing a string at _name_ and fill provided buffer. If unable, fill the buffer with default_value.
STBJDEF int stbj_read_string_name(stbj_cursor* context, const char* name, char* buffer, int buffer_size, const char* default_value)
{
    STBJ_ASSERT(context);
    STBJ_ASSERT(context->cursor);
    STBJ_ASSERT(context->type != STBJ_ERROR);
    STBJ_ASSERT(name);
    STBJ_ASSERT(buffer);
    STBJ_ASSERT(buffer_size > 0);

    int pos = stbj_find_name(context, name);
    if (pos >= 0) 
        return stbj_read_string_index(context, pos, buffer,buffer_size, default_value);
    else
    {
        int buffer_index = 0;
        while((buffer[buffer_index++] = *default_value++) && buffer_index < (buffer_size-1));
    }
    return 0;
}
#endif // STB_JSON_IMPLEMENTATION

/*
   revision history:
      0.1     (2019-06-20)
              Parsing basic numbers, reals and string
      0.2     (2019-06-20)
              Parsing other context (array/objects)
      0.3     (2019-06-28)
              Parsing errors properly communicated to client
      0.4     (2019-07-16)
              Management of special values true/false/null
      0.5     (2019-07-17)
              Handling of newline and carriage return chars
      0.6     (2019-07-23)
              Parsing scape characters, ignore hex values
*/


/*
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2019 Ricard Pillosu
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
------------------------------------------------------------------------------
*/
