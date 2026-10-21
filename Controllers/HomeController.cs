using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using NICsystem.Models;

namespace NICsystem.Controllers;

public class HomeController : Controller
{
    private readonly IConfiguration _configuration;
    private readonly IHostEnvironment _environment;
    private readonly ILogger<HomeController> _logger;

    public HomeController(IConfiguration configuration, IHostEnvironment environment, ILogger<HomeController> logger)
    {
        _configuration = configuration;
        _environment = environment;
        _logger = logger;
    }

    public IActionResult Index()
    {
        return View();
    }

    public IActionResult Privacy()
    {
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> DatabaseConnection()
    {
        if (!_environment.IsDevelopment())
        {
            return NotFound();
        }

        var connectionString = _configuration.GetConnectionString("DefaultConnection");
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogError("Database connection test failed: ConnectionStrings:DefaultConnection is not configured.");
            ViewBag.Success = false;
            ViewBag.Message = "The database connection test could not run. Check the development configuration and application logs.";
            return View();
        }

        try
        {
            var options = new DbContextOptionsBuilder<DbContext>()
                .UseSqlServer(connectionString)
                .Options;
            await using var context = new DbContext(options);
            var connection = context.Database.GetDbConnection();
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT DB_NAME(), @@VERSION;";
            await using var reader = await command.ExecuteReaderAsync();
            await reader.ReadAsync();

            ViewBag.Success = true;
            ViewBag.DatabaseName = reader.GetString(0);
            ViewBag.ServerVersion = reader.GetString(1);
        }
        catch (Exception exception)
        {
            _logger.LogError(exception, "Database connection test failed.");
            ViewBag.Success = false;
            ViewBag.Message = "The application could not connect to the database. Check the development application logs for details.";
        }

        return View();
    }

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error()
    {
        return View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
    }
}
